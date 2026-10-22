require "rails_helper"

RSpec.describe DataRetention do
  describe "schedule inventory" do
    it "classifies every column of every table explicitly" do
      connection = ActiveRecord::Base.connection
      tables = connection.data_sources.sort
      inventory = YAML.safe_load_file(described_class::CONFIG).fetch("column_classifications")
      expect(inventory.keys.sort).to eq(tables)
      tables.each do |table|
        columns = connection.columns(table).map(&:name).sort
        classifications = inventory.fetch(table)
        expect(classifications.keys.sort).to eq(columns), "Unclassified columns in #{table}"
        expect(classifications.values - %w[pii financial non-personal system]).to be_empty
      end
      application_tables = tables.reject { |table| table.start_with?("solid_queue_") ||
        %w[ar_internal_metadata schema_migrations site_settings runtime_executions runtime_throttle_buckets
          privacy_email_suppressions].include?(table) }
      expect(described_class.schedule.keys.sort).to eq(application_tables.sort)
    end

    it "accounts for every classified PII column in a runnable rule or an explicit exception" do
      configuration = YAML.safe_load_file(described_class::CONFIG)
      inventory = configuration.fetch("column_classifications")
      exceptions = YAML.safe_load_file(Rails.root.join("config/data_retention_pii_elsewhere.yml"))
        .fetch("tables")
      uncovered = inventory.to_h do |table, columns|
        rule = described_class.schedule[table]
        runnable = DataRetentionPurgeJob::RUNNABLE.include?(table) &&
          %w[anonymize delete].include?(rule&.fetch("action", nil))
        covered = runnable ? rule.fetch("pii_columns") : []
        [table, columns.filter_map { |name, classification| name if classification == "pii" && !covered.include?(name) }]
      end.reject { |_table, columns| columns.empty? }
      expect(exceptions.keys.sort).to eq(uncovered.keys.sort)
      exceptions.each do |table, exception|
        expect(exception.fetch("reason")).to be_present
        expect(exception.fetch("columns").sort).to eq(uncovered.fetch(table).sort), table
      end
    end
  end

  it "uses the end of the calendar year for the seven-year clock" do
    expect(described_class.cutoff("7_years_after_year_end", at: Time.zone.parse("2026-10-22")))
      .to eq(Time.zone.parse("2019-01-01"))
  end

  it "removes buyer and attendee details while preserving money rows and amounts" do
    user = create(:user)
    order = create(:order, user: user, completed_at: 8.years.ago, buyer_email: "buyer@example.com")
    ticket = create(:ticket, order: order, ticket_type: create(:ticket_type, event: order.event),
      attendee_name: "Buyer", attendee_email: "attendee@example.com", holder_email: "buyer@example.com")
    payment = create(:payment, order: order, amount_cents: order.total_cents,
      provider_payload: { "billing_details" => { "email" => "buyer@example.com" } })

    described_class.anonymize_order!(order)

    expect(order.reload).to have_attributes(total_cents: 5250, user_id: nil, buyer_name: "Deleted buyer",
      buyer_phone: nil)
    expect(order.buyer_email).to end_with("@privacy.invalid")
    expect(order.retention_anonymized_at).to be_present
    expect(ticket.reload).to have_attributes(attendee_name: nil, attendee_email: nil, holder_email: nil)
    expect(payment.reload).to have_attributes(amount_cents: 5250, provider_payload: {})
    expect { described_class.anonymize_order!(order) }.not_to change { order.reload.buyer_email }
  end
end

RSpec.describe DataRetention, "pending-order safety" do
  let(:order) { create(:order, :pending, created_at: 100.days.ago, expires_at: 100.days.ago) }

  it "covers every provider payment, intent, or session reference on orders" do
    references = Order.column_names.grep(/\A(?:stripe|provider|clover)_(?:payment|refund|intent|session).*_(?:id|reference)\z/)
    expect(described_class::ORDER_PROVIDER_REFERENCES).to contain_exactly(*references)
  end

  %w[payments refunds disputes tickets].each do |association|
    it "keeps a pending order with #{association}" do
      allow(order).to receive(association).and_return(double(exists?: true))
      expect(described_class.delete_pending_order!(order)).to be(false)
      expect(Order.exists?(order.id)).to be(true)
    end
  end

  {
    "privacy requests" => PrivacyRequest,
    "card-present attempts" => CardPresentPaymentAttempt,
    "live-money authorizations" => LiveMoneyProofAuthorization,
    "fee components" => FeeComponent,
    "checkout retry tombstones" => CheckoutAttempt,
    "message deliveries" => MessageDelivery
  }.each do |label, model|
    it "keeps a pending order with #{label}" do
      allow(model).to receive(:where).and_call_original
      allow(model).to receive(:where).with(order_id: order.id).and_return(double(exists?: true))
      expect(described_class.delete_pending_order!(order)).to be(false)
      expect(Order.exists?(order.id)).to be(true)
    end
  end

  it "keeps an order while a checkout lease for its digest is active" do
    keyed_order = create(:order, :pending, checkout_key_digest: "a" * 64,
      created_at: 100.days.ago, expires_at: 100.days.ago)
    CheckoutAttempt.create!(checkout_key_digest: "a" * 64, request_digest: "b" * 64,
      status: :processing, lease_token_digest: "c" * 64, lease_expires_at: 1.minute.from_now)
    expect(described_class.delete_pending_order!(keyed_order)).to be(false)
    expect(Order.exists?(keyed_order.id)).to be(true)
  end

  it "keeps a reserved checkout retry tombstone permanently" do
    tombstone = CheckoutAttempt.create!(checkout_key_digest: "d" * 64,
      request_digest: "e" * 64, status: :reserved, order: order)
    expect(described_class.delete_pending_order!(order)).to be(false)
    expect(CheckoutAttempt.exists?(tombstone.id)).to be(true)
  end

  it "keeps an order referenced by a webhook event" do
    WebhookEvent.create!(provider: "stripe", provider_event_id: SecureRandom.uuid,
      event_type: "test.event", payload: { order_reference: order.reference })
    expect(described_class.delete_pending_order!(order)).to be(false)
  end

  it "keeps an order referenced by a provider event" do
    MessageProviderEvent.create!(provider: "resend", provider_event_id: SecureRandom.uuid,
      provider_message_id: SecureRandom.uuid, event_type: "email.delivered",
      occurred_at: Time.current, received_at: Time.current,
      payload: { order_reference: order.reference })
    expect(described_class.delete_pending_order!(order)).to be(false)
  end

  it "blocks an unlisted foreign-key child instead of deleting it recursively" do
    note = SupportNote.create!(order: order, event: order.event,
      author_user: create(:user, :admin), body: "Preserve this note")
    expect(described_class.delete_pending_order!(order)).to be(false)
    expect(SupportNote.exists?(note.id)).to be(true)
    expect(Order.exists?(order.id)).to be(true)
  end

  %w[stripe_payment_intent_id stripe_refund_id].each do |reference|
    it "keeps a legacy pending order with #{reference} and no payment row" do
      order.update!(reference => "provider-#{SecureRandom.hex(6)}")
      expect(order.payments).not_to exist
      expect(described_class.delete_pending_order!(order)).to be(false)
      expect(Order.exists?(order.id)).to be(true)
    end
  end

  it "rechecks a newly attached payment after taking the order lock" do
    original = order.method(:lock!)
    allow(order).to receive(:lock!) do
      original.call
      create(:payment, order: order)
    end
    expect(described_class.delete_pending_order!(order)).to be(false)
    expect(Order.exists?(order.id)).to be(true)
  end
end

RSpec.describe DataRetention, "indirect legal holds" do
  let(:admin) { create(:user, :admin) }
  let(:order) { create(:order) }

  it "resolves an export request through its event and organization" do
    export = OrganizerSalesExportRequest.create!(event: order.event, actor_user: admin,
      filters: {}, columns: [])
    LegalHold.place!(scope_type: "organization", scope_value: order.event.organization_id.to_s,
      reason: "Preserve organizer exports", actor: admin)
    expect(described_class.held?(export)).to be(true)
  end

  %w[Order Event Organization].each do |subject_type|
    it "resolves an audit log's #{subject_type.downcase} subject" do
      subject = { "Order" => order, "Event" => order.event,
        "Organization" => order.event.organization }.fetch(subject_type)
      log = AuditLogger.record!(action: "retention.test", auditable: subject, actor: admin)
      scope = { "Order" => "order", "Event" => "event", "Organization" => "organization" }.fetch(subject_type)
      LegalHold.place!(scope_type: scope, scope_value: subject.id.to_s,
        reason: "Preserve subject audit history", actor: admin)
      expect(described_class.held?(log)).to be(true)
    end
  end

  it "finds a ticket holder user hold" do
    holder = create(:user)
    ticket = create(:ticket, order: order, event: order.event, holder_user: holder)
    LegalHold.place!(scope_type: "user", scope_value: holder.id.to_s,
      reason: "Preserve holder records", actor: admin)
    expect(described_class.held?(ticket)).to be(true)
  end

  it "finds a transfer recipient email hold" do
    ticket = create(:ticket, order: order, event: order.event)
    transfer = create(:ticket_transfer, ticket: ticket, recipient_email: "recipient@example.com")
    LegalHold.place!(scope_type: "buyer_email", scope_value: transfer.recipient_email,
      reason: "Preserve recipient records", actor: admin)
    expect(described_class.held?(transfer)).to be(true)
  end

  it "finds a delivery recipient email hold" do
    delivery = create(:message_delivery, order: order, recipient: "recipient@example.com")
    LegalHold.place!(scope_type: "buyer_email", scope_value: delivery.recipient,
      reason: "Preserve recipient messages", actor: admin)
    expect(described_class.held?(delivery)).to be(true)
  end

  it "finds a delivery requested-by user hold" do
    sender = create(:user)
    delivery = create(:message_delivery, order: order, requested_by: sender)
    LegalHold.place!(scope_type: "user", scope_value: sender.id.to_s,
      reason: "Preserve sender messages", actor: admin)
    expect(described_class.held?(delivery)).to be(true)
  end

  it "follows a refund reconciliation audit and digest back to a held order" do
    refund = create(:refund, order: order)
    audit = AuditLogger.record!(action: "refund_reconciliation.unable", auditable: refund,
      actor: admin, metadata: { reason: "Buyer asked for a call" })
    digest = create(:message_delivery, order: nil, event: order.event, recipient: admin.email,
      template: "refund_reconciliation_digest", status: :sent,
      metadata: { items: [{ order_reference: order.reference }] })
    LegalHold.place!(scope_type: "order", scope_value: order.id.to_s,
      reason: "Preserve refund reconciliation", actor: admin)

    expect(described_class.held?(audit)).to be(true)
    expect(described_class.held?(digest)).to be(true)
  end
end
