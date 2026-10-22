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
        allowed = table == "orders" ? ["provider reference", "money", "pii", "non-personal"] :
          %w[pii financial non-personal system]
        expect(classifications.values - allowed).to be_empty
      end
      application_tables = tables.reject { |table| table.start_with?("solid_queue_") ||
        %w[ar_internal_metadata schema_migrations site_settings runtime_executions runtime_throttle_buckets
          privacy_email_suppressions].include?(table) }
      expect(described_class.schedule.keys.sort).to eq(application_tables.sort)
    end

    it "lists every classified PII column in each anonymizer's allow-list" do
      configuration = YAML.safe_load_file(described_class::CONFIG)
      inventory = configuration.fetch("column_classifications")
      DataRetentionPurgeJob::RUNNABLE.each do |table|
        rule = described_class.schedule.fetch(table)
        next unless rule.fetch("action") == "anonymize"

        pii = inventory.fetch(table).filter_map { |name, kind| name if kind == "pii" }
        expect(rule.fetch("pii_columns").sort).to eq(pii.sort), table
      end
    end

    it "removes populated PII sentinels from a real row of every anonymizable table" do
      # This is a column-coverage fixture. The independent relationship specs
      # below exercise holds and money with valid associated records.
      baseline_order = create(:order)
      ActiveRecord::Base.connection.execute("SET LOCAL session_replication_role = replica")
      DataRetentionPurgeJob::RUNNABLE.each do |table|
        next unless described_class.schedule.fetch(table).fetch("action") == "anonymize"

        model = table.classify.constantize
        pii = described_class.schedule.fetch(table).fetch("pii_columns")
        sentinel = "PIISENTINEL#{SecureRandom.hex(4)}"
        row = if table == "orders"
          created = create(:order, buyer_email: "#{sentinel}@example.test")
          created.update_columns(buyer_name: sentinel, buyer_phone: sentinel,
            refund_reason: sentinel, marketing_opt_in: true)
          created
        else
          attrs = model.columns.each_with_object({}) do |column, values|
            next if column.name == "id"

            if pii.include?(column.name)
              values[column.name] = case column.type
              when :jsonb then column.name == "verified_emails" ? [sentinel] : { "value" => sentinel }
              when :boolean then true
              when :integer, :bigint then 123_456
              when :inet then "127.0.0.77"
              else column.limit ? sentinel.first(column.limit) : sentinel
              end
            elsif !column.null && column.default.nil?
              values[column.name] = case column.type
              when :datetime, :date then 8.years.ago
              when :jsonb then {}
              when :integer, :bigint then 1
              when :boolean then false
              else "x"
              end
            end
          end
          attrs["order_id"] = baseline_order.id if %w[message_deliveries support_notes].include?(table)
          attrs["wire_body_digest"] = Digest::SHA256.hexdigest(attrs.fetch("outbound_wire_body")) if
            table == "message_deliveries"
          id = model.insert_all!([attrs], returning: %w[id]).rows.first.first
          model.find(id)
        end
        expect(pii).not_to be_empty, table
        originals = pii.to_h { |column| [column, row.public_send(column)] }
        pii.each do |column|
          value = row.public_send(column)
          expect(value).to be_present, "#{table}.#{column} fixture was empty"
        end

        described_class.anonymize!(row)
        pii.each do |column|
          expect(row.reload.public_send(column)).not_to eq(originals.fetch(column)), "#{table}.#{column} survived"
        end
        expect(row.reload.marketing_opt_in).to be(false) if table == "orders"
        expect(row.reload.holder_user_id).to be_nil if table == "tickets"
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

  it "rolls back child anonymization when a hold appears before the final order write" do
    order = create(:order, completed_at: 8.years.ago)
    ticket = create(:ticket, order: order, event: order.event,
      ticket_type: create(:ticket_type, event: order.event), attendee_email: "buyer@example.com")
    actor = create(:user, :admin)
    order_checks = 0
    allow(RetentionGuard).to receive(:protected?).and_wrap_original do |original, record|
      if record.is_a?(Order) && record.id == order.id && (order_checks += 1) == 2
        LegalHold.place!(scope_type: "order", scope_value: order.id.to_s,
          reason: "Preserve during anonymization", actor: actor)
      end
      original.call(record)
    end

    expect(described_class.anonymize_order!(order)).to be(false)
    expect(ticket.reload.attendee_email).to eq("buyer@example.com")
    expect(order.reload.buyer_email).to eq("buyer@example.com")
  end
end

RSpec.describe RetentionGuard do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DESTRUCTIVE_ENABLED").and_return("true")
    SiteSetting.instance.update_columns(retention_purge_enabled: true)
  end

  it "protects a fee notice through its event's unresolved refund and its owner's hold" do
    owner = create(:user)
    order = create(:order, completed_at: 8.years.ago)
    change = FeeChange.create!(created_by: owner, old_terms: { "service_fee_percent" => "1" },
      new_terms: { "service_fee_percent" => "2" }, effective_at: 8.years.ago, created_at: 8.years.ago)
    notice = FeeChangeNotice.create!(fee_change: change, organization: order.event.organization,
      owner: owner, event: order.event, recipient_email: owner.email, buyer_fee_percent: 2,
      fee_policy: "buyer", created_at: 8.years.ago)
    refund = create(:refund, order: order, status: :pending)

    expect(described_class.protected?(notice)).to be(true)
    DataRetentionPurgeJob.perform_now
    expect(notice.reload.recipient_email).to eq(owner.email)

    refund.update!(status: :succeeded)
    LegalHold.place!(scope_type: "user", scope_value: owner.id.to_s,
      reason: "Preserve owner records", actor: create(:user, :admin))
    expect(described_class.protected?(notice)).to be(true)
    expect(described_class.protected?(change)).to be(true)
  end

  it "protects a fee change through a hold on its notice's event" do
    order = create(:order)
    owner = create(:user)
    change = FeeChange.create!(created_by: owner, old_terms: { "service_fee_percent" => "1" },
      new_terms: { "service_fee_percent" => "2" }, effective_at: 8.years.ago)
    FeeChangeNotice.create!(fee_change: change, organization: order.event.organization,
      owner: owner, event: order.event, recipient_email: owner.email, buyer_fee_percent: 2,
      fee_policy: "buyer")
    LegalHold.place!(scope_type: "event", scope_value: order.event_id.to_s,
      reason: "Preserve fee notice event", actor: create(:user, :admin))

    expect(described_class.protected?(change)).to be(true)
  end

  it "resolves nested order, refund, payment, and ticket references from persisted metadata" do
    order = create(:order)
    refund = create(:refund, order: order, status: :pending)
    ticket = create(:ticket, order: order, event: order.event)
    payment = refund.payment
    actor = create(:user, :admin)
    shapes = [
      { order_id: order.id },
      { items: [{ order_reference: order.reference }] },
      { reconciliation: { refund_id: refund.id } },
      { payment_id: payment.id },
      { ticket_id: ticket.id }
    ]
    logs = shapes.map do |metadata|
      AuditLogger.record!(action: "retention.metadata_reference", auditable: actor,
        actor: actor, metadata: metadata)
    end

    expect(described_class.protected_batch?(logs).values).to all(be(true))
    expect(logs.size).to eq(5)
  end
end

RSpec.describe DataRetention, "pending-order safety" do
  let(:order) { create(:order, :pending, created_at: 100.days.ago, expires_at: 100.days.ago) }

  it "classifies every order column and uses every provider reference to block purge" do
    classifications = YAML.safe_load_file(DataRetention::CONFIG).fetch("column_classifications").fetch("orders")
    expect(classifications.keys.sort).to eq(Order.column_names.sort)
    expect(classifications.values.uniq - ["provider reference", "money", "pii", "non-personal"]).to be_empty
    references = classifications.filter_map { |column, kind| column if kind == "provider reference" }
    expect(described_class::ORDER_PROVIDER_REFERENCES).to contain_exactly(*references)
    references.each do |column|
      referenced = create(:order, :pending, created_at: 100.days.ago, expires_at: 100.days.ago)
      referenced.update_column(column, "provider_#{referenced.id}")
      expect(described_class.delete_pending_order!(referenced)).to be(false)
    end
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
