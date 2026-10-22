require "rails_helper"

RSpec.describe PrivacyRequestProcessor do
  let(:admin) { create(:user, :admin) }
  let(:user) { create(:user) }
  let!(:order) { create(:order, user: user, buyer_email: user.email) }
  let(:privacy_request) do
    PrivacyRequest.create!(kind: "deletion", user: user, requester_email: user.email,
      status: "verified", verified_at: Time.current, verified_by: admin)
  end

  before do
    allow(ClerkIdentity).to receive(:delete_user).and_return(true)
    allow(EmailService).to receive(:send_privacy_request_confirmation_async).and_return(
      build_stubbed(:message_delivery, id: 1))
    allow(MessageDeliveryJob).to receive(:perform_now)
  end

  it "shows kept and deleted records with reasons" do
    preview = described_class.new(privacy_request).preview
    expect(preview[:retained]).to include(include(table: "orders", count: 1,
      action: "anonymize"))
    expect(preview[:blockers]).to be_empty
  end

  it "anonymizes retained records, removes account contact details, and audits execution" do
    EventFavorite.create!(user: user, event: order.event)
    described_class.new(privacy_request).execute!(actor: admin)
    expect(order.reload.buyer_email).to end_with("@privacy.invalid")
    expect(order.total_cents).to eq(5250)
    expect(user.reload.email).to be_nil
    expect(EventFavorite.where(user_id: user.id)).not_to exist
    expect(privacy_request.reload.status).to eq("completed")
    expect(AuditLog.where(action: "privacy_request.executed", auditable: privacy_request)).to exist
  end

  it "blocks deletion under a legal hold" do
    processor = described_class.new(privacy_request)
    expect(processor.preview[:blockers]).to be_empty
    LegalHold.place!(scope_type: "buyer_email", scope_value: user.email,
      reason: "Preserve this person's records", actor: admin)
    expect { processor.execute!(actor: admin) }
      .to raise_error(PrivacyRequestProcessor::Blocked)
    expect(order.reload.buyer_email).to eq(user.email)
  end

  it "includes account activity and order data in the access JSON" do
    favorite = EventFavorite.create!(user: user, event: order.event)
    access = PrivacyRequest.create!(kind: "access", user: user, requester_email: user.email,
      status: "verified", verified_at: Time.current, verified_by: admin)

    data = described_class.new(access).export

    expect(data[:account]).to include("email" => user.email)
    expect(data[:orders].first[:order]).to include("id" => order.id)
    expect(data[:saved_events].first).to include("id" => favorite.id)
  end

  it "includes guest orders sent to the verified account email" do
    guest_order = create(:order, user: nil, buyer_email: user.email.upcase)

    expect(described_class.new(privacy_request).orders.map(&:id)).to contain_exactly(order.id, guest_order.id)
  end

  it "shows an account-linked purchase without another buyer's contact and preserves that buyer on deletion" do
    bob = create(:user)
    order.update!(buyer_email: bob.email, buyer_name: "Bob Buyer", buyer_phone: "671-555-0199")
    access = PrivacyRequest.create!(kind: "access", user: user, requester_email: user.email,
      status: "verified", verified_at: Time.current, verified_by: admin)
    exported = described_class.new(access).export[:orders].first[:order]
    expect(exported).to include("id" => order.id)
    expect(exported.keys).not_to include("buyer_email", "buyer_name", "buyer_phone")
    described_class.new(privacy_request).execute!(actor: admin)
    expect(order.reload).to have_attributes(user_id: nil, buyer_email: bob.email,
      buyer_name: "Bob Buyer", buyer_phone: "671-555-0199")
  end

  it "pseudonymizes earlier requests while keeping dates, type, and outcome" do
    earlier = PrivacyRequest.create!(kind: "access", user: user, requester_email: user.email,
      status: "completed", verified_at: 2.days.ago, executed_at: 1.day.ago,
      result: { "personal_note" => user.email })
    earlier_guest = PrivacyRequest.create!(kind: "access", order: order, requester_email: user.email,
      status: "completed", verified_at: 3.days.ago, executed_at: 2.days.ago)
    earlier_audit = AuditLogger.record!(action: "privacy_request.executed", auditable: earlier_guest,
      actor: admin, metadata: { email: user.email })
    described_class.new(privacy_request).execute!(actor: admin)
    expect(earlier.reload).to have_attributes(kind: "access", status: "completed", result: {})
    expect(earlier.requester_email).to end_with("@privacy.invalid")
    expect(earlier.executed_at).to be_present
    expect(earlier_guest.reload.requester_email).to end_with("@privacy.invalid")
    expect(earlier_audit.reload.metadata).to eq({})
    expect(privacy_request.reload.requester_email).to end_with("@privacy.invalid")
  end
end

RSpec.describe PrivacyRequestProcessor, "review findings" do
  let(:admin) { create(:user, :admin) }
  let(:buyer) { create(:user) }
  let(:order) { create(:order, user: buyer, buyer_email: buyer.email, event: create(:event, :past)) }
  let(:privacy_request) do
    PrivacyRequest.create!(kind: "deletion", user: buyer, requester_email: buyer.email,
      status: "verified", verified_at: Time.current, verified_by: admin)
  end

  before do
    allow(ClerkIdentity).to receive(:delete_user).and_return(true)
    allow(S3Service).to receive(:delete_upload!)
    allow(EmailService).to receive(:send_privacy_request_confirmation_async).and_return(
      build_stubbed(:message_delivery, id: 1))
    allow(MessageDeliveryJob).to receive(:perform_now)
  end

  it "keeps an order audit log whose actor has a user hold while processing other records" do
    held_actor = create(:user)
    held = AuditLogger.record!(action: "retention.held", auditable: order,
      actor: held_actor, metadata: { note: "preserve" })
    refund = create(:refund, order: order)
    held_reconciliation = AuditLogger.record!(action: "refund_reconciliation.held", auditable: refund,
      actor: held_actor, metadata: { note: "preserve reconciliation" })
    ordinary = AuditLogger.record!(action: "retention.ordinary", auditable: order,
      actor: admin, metadata: { note: "redact" })
    LegalHold.place!(scope_type: "user", scope_value: held_actor.id,
      reason: "Preserve actor evidence", actor: admin)
    described_class.new(privacy_request).execute!(actor: admin)
    expect(held.reload.metadata).to eq("note" => "preserve")
    expect(held_reconciliation.reload.metadata).to eq("note" => "preserve reconciliation")
    expect(ordinary.reload.metadata).to eq({})
    expect(order.reload.buyer_email).to end_with("@privacy.invalid")
  end

  it "returns only a preview with zero writes and provider calls in dry-run mode" do
    SiteSetting.delete_all
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DRY_RUN").and_return(nil)
    writes = []
    callback = ->(_name, _started, _finished, _id, payload) {
      writes << payload[:sql] if payload[:sql].to_s.match?(/\A\s*(INSERT|UPDATE|DELETE|ALTER|TRUNCATE)\b/i)
    }
    admin; buyer; order; privacy_request
    result = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      result = described_class.new(privacy_request).execute!(actor: admin)
    end
    expect(result).to include(dry_run: true, retained: be_an(Array))
    expect(writes).to be_empty
    expect(S3Service).not_to have_received(:delete_upload!)
    expect(ClerkIdentity).not_to have_received(:delete_user)
    expect(EmailService).not_to have_received(:send_privacy_request_confirmation_async)
    expect(SiteSetting.count).to eq(0)
    expect(order.reload.buyer_email).to eq(buyer.email)
  end

  it "keeps a transferred holder's ticket, wallet pass, and identity out of deletion" do
    ticket = create(:ticket, order: order, event: order.event, ticket_type: create(:ticket_type, event: order.event))
    holder = create(:user)
    ticket.update_columns(holder_user_id: holder.id, holder_email: holder.email,
      attendee_name: holder.first_name, status: Ticket.statuses.fetch("transferred"))
    wallet = WalletPass.record!(provider: "apple", serial_number: "transferred-#{ticket.id}", ticket: ticket)
    holder_note = SupportNote.create!(order: order, ticket: ticket, event: order.event,
      author_user: admin, body: "Contact #{holder.email}")
    preview = described_class.new(privacy_request).preview
    expect(preview[:deleted]).to include(include(table: "wallet_passes", count: 0))
    described_class.new(privacy_request).execute!(actor: admin)
    expect(ticket.reload).to have_attributes(holder_user_id: holder.id, holder_email: holder.email,
      attendee_name: holder.first_name)
    expect(WalletPass.exists?(wallet.id)).to be(true)
    expect(holder_note.reload.body).to eq("Contact #{holder.email}")
  end

  it "exports a transfer fact without the new holder identity or their registration answer" do
    ticket = create(:ticket, order: order, event: order.event, ticket_type: create(:ticket_type, event: order.event))
    holder = create(:user)
    ticket.update_columns(holder_user_id: holder.id, holder_email: holder.email,
      attendee_email: holder.email, attendee_name: holder.first_name,
      status: Ticket.statuses.fetch("transferred"))
    question = create(:registration_question, event: order.event)
    RegistrationResponse.create!(order: order, registration_question: question,
      kind_snapshot: question.kind_before_type_cast, prompt_snapshot: question.prompt,
      answer: { "value" => "holder secret" }, answered_at: Time.current)
    access = PrivacyRequest.create!(kind: "access", user: buyer, requester_email: buyer.email,
      status: "verified", verified_at: Time.current, verified_by: admin)
    exported = described_class.new(access).export[:orders].first
    expect(exported[:tickets]).to eq([{ "id" => ticket.id, "status" => "transferred" }])
    expect(exported[:registration_responses]).to be_empty
    expect(exported.to_json).not_to include(holder.email, holder.first_name, "holder secret")
  end

  it "redacts refund reason, event-only notes, audit metadata, and recipient metadata" do
    order.update_columns(refund_reason: "Call #{buyer.email}")
    note = SupportNote.create!(event: order.event, author_user: admin, body: "Call #{buyer.email}")
    audit = AuditLogger.record!(action: "retention.test", auditable: order.event,
      actor: admin, metadata: { email: buyer.email })
    request_audit = AuditLogger.record!(action: "privacy_request.verified", auditable: privacy_request,
      actor: admin, metadata: { note: "Call the requester" })
    delivery = create(:message_delivery, order: order, recipient: buyer.email,
      metadata: { email: buyer.email })
    deleted_email = buyer.email.dup
    described_class.new(privacy_request).execute!(actor: admin)
    expect(order.reload.refund_reason).to be_nil
    expect(note.reload.body).to eq("[redacted]")
    expect(audit.reload.metadata).to eq({})
    expect(request_audit.reload.metadata).to eq({})
    expect(delivery.reload.metadata).to eq({})
    expect(PrivacyEmailSuppression.for?(deleted_email)).to be(true)
  end

  it "includes reconciliation audit and digest records in the deletion plan and redacts them" do
    refund = create(:refund, order: order, reason: "Call #{buyer.email}")
    audit = AuditLogger.record!(action: "refund_reconciliation.unable", auditable: refund,
      actor: admin, metadata: { reason: "Call #{buyer.email}" })
    run = order.event.create_event_cancellation_refund_run!(started_by: admin)
    item = run.items.create!(order: order, status: :refunded, amount_cents: 1000,
      last_error: "Call #{buyer.email}")
    digest = create(:message_delivery, order: nil, event: order.event, recipient: admin.email,
      template: "refund_reconciliation_digest", status: :sent,
      metadata: { items: [{ order_reference: order.reference }] })
    provider_event = MessageProviderEvent.create!(message_delivery: digest, provider: "resend",
      provider_event_id: SecureRandom.uuid, provider_message_id: SecureRandom.uuid,
      event_type: "email.delivered", occurred_at: Time.current, received_at: Time.current,
      payload: { order_reference: order.reference })

    preview = described_class.new(privacy_request).preview
    expect(preview[:retained]).to include(include(table: "cancellation refund items", count: 1),
      include(table: "requester audit logs", count: 1),
      include(table: "recipient message metadata", count: 1))

    described_class.new(privacy_request).execute!(actor: admin)
    expect(refund.reload.reason).to be_nil
    expect(item.reload.last_error).to be_nil
    expect(audit.reload.metadata).to eq({})
    expect(digest.reload.metadata).to eq({})
    expect(provider_event.reload.payload).to eq({})
  end
end

RSpec.describe "Privacy email suppression" do
  it "stores only a keyed digest and prevents a later send to the deleted address" do
    email = "deleted-buyer@example.com"
    PrivacyEmailSuppression.suppress!(email)
    expect(PrivacyEmailSuppression.last.email_digest).not_to include(email)
    order = create(:order, buyer_email: email)
    allow(MessageDeliveryJob).to receive(:perform_later)
    delivery = EmailService.send_order_confirmation_async(order)
    expect(delivery).to have_attributes(status: "suppressed", recipient: "deleted@privacy.invalid", metadata: {})
    expect(MessageDeliveryJob).to have_received(:perform_later).with(delivery.id)
  end
end
