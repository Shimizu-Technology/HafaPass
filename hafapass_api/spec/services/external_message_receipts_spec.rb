require "rails_helper"

RSpec.describe ExternalMessageReceipts, :webmock do
  include ActiveJob::TestHelper
  let(:admin) { create(:user, :admin) }
  let(:proof) { "receipt-origin:2026-10-26/csg-learn-dm" }

  def receipt(**attributes)
    MessageProviderEvent.create!({ provider: "resend", provider_event_id: SecureRandom.uuid,
      provider_message_id: SecureRandom.uuid, event_type: "email.delivered", occurred_at: 1.day.ago,
      received_at: 1.day.ago, payload: {} }.merge(attributes))
  end

  def classify(rows, actor: admin, reference: proof, identities: nil)
    described_class.call(actor: actor, proof_reference: reference,
      receipts: identities || rows.map { |row| row.attributes.slice(*described_class::IDENTITY_KEYS) })
  end

  it "atomically classifies the four reviewed receipts without changing any receipt byte or scheduling work" do
    rows = 2.times.flat_map do
      message_id = SecureRandom.uuid
      %w[email.sent email.delivered].map { |type| receipt(provider_message_id: message_id, event_type: type) }
    end
    before = rows.map(&:attributes)
    expect { classify(rows) }.to change { AuditLog.where(action: described_class::MANUAL_ACTION).count }.by(4)
    expect(rows.map { |row| row.reload.attributes }).to eq(before)
    expect(MessageDelivery.count).to eq(0)
    expect(enqueued_jobs).to be_empty
    expect(described_class.resolved.pluck(:id)).to match_array(rows.map(&:id))
    expect(AuditLog.where(action: described_class::MANUAL_ACTION).pluck(:actor_user_id).uniq).to eq([admin.id])
    expect(AuditActions.fetch(described_class::MANUAL_ACTION)[:audience]).to eq(["admin_only"])
  end

  it "retries deterministically, including after audit payload redaction, and rejects conflicting proof" do
    row = receipt
    first = classify([row]).sole
    AuditLog.redact!(AuditLog.where(id: first.id), metadata: {})
    expect(classify([row]).sole.id).to eq(first.id)
    expect { classify([row], reference: "receipt-origin:different-proof") }.to raise_error(described_class::Rejected)
    expect(AuditLog.where(action: described_class::MANUAL_ACTION).count).to eq(1)
    expect(described_class.resolved).to include(row)
  end

  it "requires a persisted current admin even when the caller holds a stale admin object" do
    row = receipt
    [nil, User.new(role: :admin), create(:user)].each do |actor|
      expect { classify([row], actor: actor) }.to raise_error(described_class::Rejected)
    end
    actor = admin
    User.where(id: actor.id).update_all(role: User.roles.fetch("attendee"))
    expect { classify([row], actor: actor) }.to raise_error(described_class::Rejected)
    expect(AuditLog.where(action: described_class::ACTIONS)).not_to exist
  end

  it "rejects malformed evidence and identity, duplicate IDs and batches larger than four" do
    row = receipt
    [nil, "", "https://example.test/recipient@example.test", "x" * 200].each do |reference|
      expect { classify([row], reference: reference) }.to raise_error(described_class::Rejected)
    end
    [[], [row, row], Array.new(5) { receipt }].each do |rows|
      expect { classify(rows) }.to raise_error(described_class::Rejected)
    end
    described_class::IDENTITY_KEYS.each do |key|
      identity = row.attributes.slice(*described_class::IDENTITY_KEYS).merge(key => key == "id" ? row.id + 900 : "wrong")
      expect { classify([row], identities: [identity]) }.to raise_error(described_class::Rejected)
    end
    duplicate_key = row.attributes.slice(*described_class::IDENTITY_KEYS).merge(id: row.id)
    expect { classify([row], identities: [duplicate_key]) }.to raise_error(described_class::Rejected)
    expect(AuditLog.where(action: described_class::ACTIONS)).not_to exist
  end

  it "rejects links, exact saved matches, errors, processed and adverse receipts as a whole batch" do
    valid = receipt
    delivery = create(:message_delivery, provider: "resend", provider_id: "exact-saved-message")
    invalid = [receipt(message_delivery: delivery), receipt(provider_message_id: delivery.provider_id),
      receipt(processing_error: "failure"), receipt(processing_error: " "), receipt(processed_at: Time.current)] +
      %w[email.bounced email.failed email.complained email.suppressed email.delivery_delayed unknown].map { |type| receipt(event_type: type) }
    invalid.each do |row|
      expect { classify([valid, row]) }.to raise_error(described_class::Rejected)
      expect(AuditLog.where(action: described_class::ACTIONS)).not_to exist
    end
  end

  it "rolls the whole batch back on audit failure even in an inherited fail-open context" do
    rows = [receipt, receipt]
    allow(AuditLog).to receive(:create_or_find_by!).and_call_original
    calls = 0
    allow(AuditLog).to receive(:create_or_find_by!).and_wrap_original do |original, *args, **kwargs, &block|
      calls += 1
      raise ActiveRecord::StatementInvalid, "synthetic audit failure" if calls == 2
      original.call(*args, **kwargs, &block)
    end
    AuditContext.set(fail_open: true) do
      expect { classify(rows) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(AuditContext.fail_open).to be(true)
    end
    expect(AuditLog.where(action: described_class::ACTIONS)).not_to exist
    expect(rows.map { |row| row.reload.processed_at }).to eq([nil, nil])
  end

  it "rolls a rejected batch back even when an enclosing caller rescues and commits its own transaction" do
    valid, invalid = receipt, receipt(processing_error: "failure")
    MessageProviderEvent.transaction do
      begin
        classify([valid, invalid])
      rescue described_class::Rejected
        # A console caller may continue other work in its own transaction.
      end
    end
    expect(AuditLog.where(action: described_class::ACTIONS)).not_to exist
  end

  it "shares actionable counts and list scopes, retains safe history, and revives matches/errors" do
    external, matched, error, unknown = Array.new(4) { receipt }
    classify([external, matched, error])
    create(:message_delivery, provider: "resend", provider_id: matched.provider_message_id)
    error.update!(processing_error: "private@example.test provider-secret-id")
    review = OperationalReview.new.call(category: "stale_message_events")
    expect(review.dig(:signals, :stale_message_events)).to eq(3)
    expect(review[:items].pluck(:id)).to match_array([matched.id, error.id, unknown.id])
    history = OperationalReview.new.call(category: "external_message_receipts")
    expect(history.dig(:history_counts, :external_message_receipts)).to eq(1)
    expect(history[:items].sole).to include(id: external.id, review_state: "external_confirmed")
    serialized = history.to_json + review.to_json
    [proof, external.provider_message_id, external.provider_event_id, "private@example.test", "provider-secret-id"].each do |private_value|
      expect(serialized).not_to include(private_value)
    end
    expect(OperationalReview.new.signals).to eq(review[:signals])
  end

  it "leaves later exact-ID reconciliation available without another send" do
    row = receipt
    classify([row])
    delivery = create(:message_delivery, provider: "resend", provider_id: row.provider_message_id, status: :sent)
    expect(OperationalReview.new.signals[:stale_message_events]).to eq(1)
    MessageProviderEventProcessor.reconcile_for!(delivery)
    expect(row.reload).to have_attributes(message_delivery_id: delivery.id, processing_error: nil)
    expect(row.processed_at).to be_present
    expect(delivery.reload).to be_delivered
    expect(described_class.resolved).not_to include(row)
    expect(OperationalReview.new.signals[:stale_message_events]).to eq(0)
  end

  it "does not classify a foreign marker through the unsigned processor entry point" do
    row = MessageProviderEventProcessor.call(provider_event_id: "unsigned", event: {
      "type" => "email.delivered", "created_at" => 1.day.ago.iso8601,
      "data" => { "email_id" => "foreign-unsigned", "tags" => { "application" => "csg_learn" } }
    })
    expect(row.payload.dig("provenance", "application")).to eq("csg_learn")
    expect(described_class.resolved).not_to include(row)
  end
end
