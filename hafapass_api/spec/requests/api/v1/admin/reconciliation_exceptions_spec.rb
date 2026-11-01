# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin reconciliation exceptions", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:headers) { auth_headers(admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organizer_profile: profile, title: "Closing Night") }
  let(:base) { "/api/v1/admin/reconciliation_exceptions" }

  # A settled $50.00 card order with verified processing evidence, so the
  # event can be finalized and the organization has a payable balance.
  def record_sale!(sale_event)
    order = create(:order, event: sale_event, subtotal_cents: 5000, service_fee_cents: 350, discount_cents: 0,
      total_cents: 5350, processing_fee_bearer_snapshot: "platform")
    item = create(:order_item, order: order, unit_price_cents: 5000, subtotal_cents: 5000, fee_cents: 350,
      organizer_proceeds_cents: 5000)
    create(:ticket, order: order, order_item: item, ticket_type: item.ticket_type, event: sale_event)
    component = create(:fee_component, order: order, order_item: item, kind: "processing", amount_cents: 185,
      estimated: false, provider_reference: "txn_fixture_#{SecureRandom.hex(8)}")
    capture = create(:payment, :succeeded, order: order, amount_cents: 5350)
    create(:stripe_fee_evidence, :verified, payment: capture, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    order
  end

  describe "listing" do
    let!(:order) { record_sale!(event) }
    let!(:mismatch) do
      create(:reconciliation_exception, order: order, payment: order.payments.sole, code: "payment_amount_mismatch",
        expected_amount_cents: 5350, actual_amount_cents: 5300, expected_currency: "usd", actual_currency: "usd",
        details: { "provider_note" => "x" * 400, "nested" => { "secret" => "dropped" } })
    end
    let!(:via_payment) do
      other = record_sale!(create(:event, :completed, organizer_profile: profile, title: "Second Show"))
      create(:reconciliation_exception, payment: other.payments.sole, code: "refund_operation_mismatch")
    end
    let!(:unlinked) { create(:reconciliation_exception, code: "payment_not_found") }
    let!(:resolved) do
      create(:reconciliation_exception, order: order, code: "stripe_processing_fee_pending", status: :resolved,
        resolved_at: 1.day.ago)
    end

    it "shows open exceptions with what each blocks and which organizations' payouts are frozen" do
      get base, headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["reconciliation_exceptions"].map { |row| row["id"] }).to contain_exactly(mismatch.id, via_payment.id, unlinked.id)
      row = body["reconciliation_exceptions"].find { |entry| entry["id"] == mismatch.id }
      expect(row).to include("code" => "payment_amount_mismatch", "status" => "open", "blocks_payouts" => true,
        "expected_amount_cents" => 5350, "actual_amount_cents" => 5300, "actions" => ["resolve"],
        "resolve_blocked_reason" => nil, "resolve_confirmation" => nil)
      expect(row["organization"]).to eq("id" => organization.id, "name" => organization.name)
      expect(row["event"]).to include("id" => event.id, "title" => "Closing Night")
      expect(row).not_to have_key("details")
      payment_row = body["reconciliation_exceptions"].find { |entry| entry["id"] == via_payment.id }
      expect(payment_row).to include("blocks_payouts" => true)
      expect(payment_row.dig("organization", "id")).to eq(organization.id)
      expect(body["reconciliation_exceptions"].find { |entry| entry["id"] == unlinked.id })
        .to include("blocks_payouts" => false, "order" => nil, "organization" => nil)
      expect(body["status_counts"]).to eq("open" => 3, "resolved" => 1)
      expect(body["open_code_counts"]).to eq("payment_amount_mismatch" => 1, "payment_not_found" => 1, "refund_operation_mismatch" => 1)
      blocks = body["payout_blocks"]
      expect(blocks["unlinked_open_count"]).to eq(1)
      expect(blocks["organizations"].sole).to include("organization" => { "id" => organization.id, "name" => organization.name },
        "open_count" => 2)
      expect(blocks["organizations"].sole["events"].map { |entry| entry["title"] }).to contain_exactly("Closing Night", "Second Show")
    end

    it "filters by status, code, organization and order number" do
      get base, params: { status: "resolved" }, headers: headers
      expect(response.parsed_body["reconciliation_exceptions"].map { |row| row["id"] }).to eq([resolved.id])

      get base, params: { status: "all", code: "payment_amount_mismatch" }, headers: headers
      expect(response.parsed_body["reconciliation_exceptions"].map { |row| row["id"] }).to eq([mismatch.id])

      other_org_issue = create(:reconciliation_exception, order: record_sale!(create(:event, :completed)), code: "payment_amount_mismatch")
      get base, params: { organization_id: organization.id }, headers: headers
      expect(response.parsed_body["reconciliation_exceptions"].map { |row| row["id"] }).to contain_exactly(mismatch.id, via_payment.id)
      expect(response.parsed_body["payout_blocks"]["organizations"].size).to eq(2)

      get base, params: { q: "##{other_org_issue.order_id}" }, headers: headers
      expect(response.parsed_body["reconciliation_exceptions"].map { |row| row["id"] }).to eq([other_org_issue.id])
    end

    it "shows scalar details and history on the detail view" do
      get "#{base}/#{mismatch.id}", headers: headers

      expect(response).to have_http_status(:ok)
      detail = response.parsed_body["reconciliation_exception"]
      expect(detail["details"]).to eq("provider_note" => "x" * 300)
      expect(detail["history"]).to eq([])
      expect(detail.dig("payment", "id")).to eq(order.payments.sole.id)
    end

    it "requires an administrator" do
      get base, headers: auth_headers(profile.user)
      expect(response).to have_http_status(:forbidden)
      post "#{base}/#{mismatch.id}/resolve", params: { note: "x" }, headers: auth_headers(profile.user), as: :json
      expect(response).to have_http_status(:forbidden)
      expect(mismatch.reload).to be_open
    end
  end

  describe "resolving" do
    it "requires a note, audits it and restores the organization's payout balance" do
      order = record_sale!(event)
      Settlements::Finalizer.call(event: event, actor: profile.user)
      issue = create(:reconciliation_exception, order: order, payment: order.payments.sole, code: "payment_amount_mismatch")
      expect(OrganizationPayoutBalance.available_cents(organization)).to eq(0)

      post "#{base}/#{issue.id}/resolve", params: { note: "  " }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("Add a note")
      expect(issue.reload).to be_open

      post "#{base}/#{issue.id}/resolve", params: { note: "Stripe balance matches; amount fixed by support." }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(issue.reload).to be_resolved
      expect(OrganizationPayoutBalance.available_cents(organization)).to eq(5000)
      audit = AuditLog.find_by!(action: "reconciliation_exception.manually_resolved", auditable: issue)
      expect(audit).to have_attributes(actor_user_id: admin.id, source: "admin", organization_id: organization.id, event_id: event.id)
      expect(audit.metadata).to include("note" => "Stripe balance matches; amount fixed by support.", "code" => "payment_amount_mismatch")
      expect(response.parsed_body.dig("reconciliation_exception", "history").sole)
        .to include("action" => "reconciliation_exception.manually_resolved", "note" => "Stripe balance matches; amount fixed by support.")

      post "#{base}/#{issue.id}/resolve", params: { note: "again" }, headers: headers, as: :json
      expect(response).to have_http_status(:conflict)
      expect(AuditLog.where(action: "reconciliation_exception.manually_resolved").count).to eq(1)
    end

    it "requires a verified-no-ledger-change confirmation and evidence note for an external Stripe refund" do
      order = record_sale!(event)
      issue = create(:reconciliation_exception, order: order, payment: order.payments.sole, code: "refund_operation_not_found")

      get "#{base}/#{issue.id}", headers: headers
      detail = response.parsed_body["reconciliation_exception"]
      expect(detail["actions"]).to eq(%w[verify_external_refund resolve])
      expect(detail["resolve_confirmation"]).to include("flag" => "verified_no_ledger_change", "evidence_note_minimum" => 20)

      post "#{base}/#{issue.id}/resolve", params: { note: "Looked at it in Stripe, all fine." }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("confirmation_required" => "verified_no_ledger_change")
      expect(response.parsed_body["error"]).to include("recording a refund")

      post "#{base}/#{issue.id}/resolve", params: { note: "ok", verified_no_ledger_change: true }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("at least 20 characters")
      expect(issue.reload).to be_open

      note = "Stripe re_123 is a duplicate webhook of refund #42 already on the order."
      post "#{base}/#{issue.id}/resolve", params: { note: note, verified_no_ledger_change: true }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(issue.reload).to be_resolved
      expect(AuditLog.where(action: "reconciliation_exception.manually_resolved", auditable: issue)).to be_empty
      audit = AuditLog.find_by!(action: "reconciliation_exception.resolved_without_ledger_change", auditable: issue)
      expect(audit).to have_attributes(actor_user_id: admin.id, organization_id: organization.id)
      expect(audit.metadata).to include("note" => note, "verified_no_ledger_change" => true, "code" => "refund_operation_not_found")
    end

    it "requires a reviewed-no-action confirmation to resolve an early fraud warning without the fraud refund" do
      order = record_sale!(event)
      issue = create(:reconciliation_exception, order: order, payment: order.payments.sole, code: "early_fraud_warning")
      note = "Buyer confirmed the purchase by phone; issuer warning withdrawn."

      post "#{base}/#{issue.id}/resolve", params: { note: note, verified_no_ledger_change: true }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("confirmation_required" => "reviewed_no_action")
      expect(issue.reload).to be_open

      post "#{base}/#{issue.id}/resolve", params: { note: note, reviewed_no_action: "true" }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(AuditLog.find_by!(action: "reconciliation_exception.reviewed_no_action", auditable: issue).metadata)
        .to include("note" => note, "reviewed_no_action" => true)
    end

    it "resolves an exception with no order or organization" do
      issue = create(:reconciliation_exception, code: "payment_not_found")

      post "#{base}/#{issue.id}/resolve", params: { note: "Charge belongs to another Stripe integration." }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(issue.reload).to be_resolved
      expect(AuditLog.find_by!(action: "reconciliation_exception.manually_resolved", auditable: issue).organization_id).to be_nil
    end
  end

  describe "late capture refunds" do
    let(:published) { create(:event, :published, organizer_profile: profile, starts_at: 5.days.from_now) }
    let(:ticket_type) { create(:ticket_type, event: published, price_cents: 2500, quantity_available: 10) }
    let(:refunds) { [] }

    before do
      SiteSetting.instance.update!(payment_mode: "test")
      allow(StripeService).to receive_messages(payment_enabled?: true, card_only_intent?: true)
      allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_late_#{SecureRandom.hex(4)}", client_secret: "secret"))
      allow(StripeService).to receive(:cancel_payment_intent).and_return(OpenStruct.new(status: "canceled"))
      allow(StripeService).to receive(:refund_payment) do |intent_id, amount_cents:, reason:, idempotency_key:, payment:|
        refunds << { intent_id: intent_id, amount_cents: amount_cents, idempotency_key: idempotency_key }
        OpenStruct.new(id: "re_late_#{refunds.length}", status: "succeeded", amount: amount_cents, currency: "usd",
          payment_intent: intent_id, metadata: { "hafapass_refund_key" => idempotency_key })
      end
      allow(EmailService).to receive(:send_order_confirmation_async)
      allow(Sentry).to receive(:capture_message)
    end

    def late_capture
      result = Commerce::OrderCreator.call(event: published, line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
        buyer_email: "late@example.com", buyer_name: "Late Buyer")
      Commerce::OrderLifecycle.cancel!(result.order)
      Commerce::OrderLifecycle.complete!(result.order, payment: result.payment,
        provider_amount_cents: result.payment.amount_cents, provider_currency: "usd")
      [result.order.reload, result.payment.reload]
    end

    it "offers Refund buyer and refunds through the shared late-capture path" do
      order, payment = late_capture
      issue = ReconciliationException.find_by!(order: order, code: Commerce::LateCaptureRefund::CODES)

      get base, params: { code: issue.code }, headers: headers
      row = response.parsed_body["reconciliation_exceptions"].sole
      expect(row).to include("actions" => %w[refund_buyer], "late_capture_owed_cents" => payment.amount_cents)
      expect(row["resolve_blocked_reason"]).to include("still owed $#{format('%.2f', payment.amount_cents / 100.0)}", "Refund buyer")

      post "#{base}/#{issue.id}/refund_buyer", headers: headers, as: :json

      expect(response).to have_http_status(:created), response.body
      expect(refunds).to eq([{ intent_id: payment.provider_payment_id, amount_cents: payment.amount_cents,
        idempotency_key: "late-capture:payment:#{payment.id}" }])
      expect(issue.reload).to be_resolved
      refund = Refund.find(response.parsed_body.dig("refund", "id"))
      audit = AuditLog.find_by!(action: "reconciliation_exception.buyer_refund_requested", auditable: issue)
      expect(audit).to have_attributes(actor_user_id: admin.id, outcome: "succeeded")
      expect(audit.metadata).to include("refund_id" => refund.id, "refund_status" => "succeeded", "amount_cents" => payment.amount_cents)
      expect(audit.id).to be > AuditLog.where(action: "refund.succeeded", auditable: refund).maximum(:id).to_i
      expect(response.parsed_body.dig("reconciliation_exception", "actions")).to eq([])

      post "#{base}/#{issue.id}/refund_buyer", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(refunds.size).to eq(1)
    end

    it "refuses a note-only resolution while the buyer is still owed, even with a confirmation flag" do
      order, payment = late_capture
      issue = ReconciliationException.find_by!(order: order, code: Commerce::LateCaptureRefund::CODES)

      [{ note: "Buyer said it is fine." }, { note: "Checked Stripe, nothing to change here.", verified_no_ledger_change: true }].each do |params|
        post "#{base}/#{issue.id}/resolve", params: params, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to include("still owed", "Refund buyer")
      end
      expect(issue.reload).to be_open
      expect(AuditLog.where(auditable: issue)).to be_empty

      # After the automatic refund fails, the guidance points to Retry refund
      # and Refund buyer stays unavailable.
      create(:refund, order: order, payment: payment, status: :failed, succeeded_at: nil, provider_refund_id: nil,
        amount_cents: payment.amount_cents, idempotency_key: Commerce::LateCaptureRefund.idempotency_key(payment))
      get "#{base}/#{issue.id}", headers: headers
      detail = response.parsed_body["reconciliation_exception"]
      expect(detail["actions"]).to eq([])
      expect(detail["resolve_blocked_reason"]).to include("Retry refund")
      post "#{base}/#{issue.id}/refund_buyer", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(refunds).to be_empty
    end

    it "refuses Refund buyer when nothing is owed or a refund is already pending, and resolves once returned" do
      order, payment = late_capture
      issue = ReconciliationException.find_by!(order: order, code: Commerce::LateCaptureRefund::CODES)
      pending = create(:refund, order: order, payment: payment, status: :pending, succeeded_at: nil, provider_refund_id: nil,
        amount_cents: payment.amount_cents, idempotency_key: "external-pending")

      post "#{base}/#{issue.id}/refund_buyer", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("still pending")
      post "#{base}/#{issue.id}/resolve", params: { note: "Waiting is too slow." }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("still pending")

      pending.update_columns(status: Refund.statuses[:succeeded], succeeded_at: Time.current, provider_refund_id: "re_outside")
      post "#{base}/#{issue.id}/refund_buyer", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("Nothing is owed")
      expect(refunds).to be_empty
      expect(AuditLog.where(action: "reconciliation_exception.buyer_refund_requested")).to be_empty

      get "#{base}/#{issue.id}", headers: headers
      expect(response.parsed_body["reconciliation_exception"]).to include("actions" => ["resolve"], "late_capture_owed_cents" => 0)
      post "#{base}/#{issue.id}/resolve", params: { note: "Refunded in the Stripe Dashboard as re_outside." }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(issue.reload).to be_resolved
    end

    it "audits a failed Refund buyer attempt after the provider call, with the failed refund" do
      order, payment = late_capture
      issue = ReconciliationException.find_by!(order: order, code: Commerce::LateCaptureRefund::CODES)
      allow(StripeService).to receive(:refund_payment)
        .and_raise(Stripe::InvalidRequestError.new("Charge already refunded", "charge"))

      post "#{base}/#{issue.id}/refund_buyer", headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(issue.reload).to be_open
      refund = order.refunds.find_by!(idempotency_key: Commerce::LateCaptureRefund.idempotency_key(payment))
      expect(refund).to be_failed
      audit = AuditLog.find_by!(action: "reconciliation_exception.buyer_refund_requested", auditable: issue)
      expect(audit).to have_attributes(outcome: "failed", actor_user_id: admin.id)
      expect(audit.metadata).to include("refund_id" => refund.id, "refund_status" => "failed",
        "error_class" => "Commerce::RefundCreator::RefundError")
    end

    it "refuses other codes and points to the existing actions for fraud warnings and external refunds" do
      order = record_sale!(event)
      fraud = create(:reconciliation_exception, order: order, payment: order.payments.sole, code: "early_fraud_warning")
      external = create(:reconciliation_exception, order: order, payment: order.payments.sole, code: "refund_operation_not_found")

      post "#{base}/#{fraud.id}/refund_buyer", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(refunds).to be_empty

      get base, headers: headers
      rows = response.parsed_body["reconciliation_exceptions"].index_by { |row| row["id"] }
      expect(rows[fraud.id]["actions"]).to eq(%w[fraud_refund resolve])
      expect(rows[external.id]["actions"]).to eq(%w[verify_external_refund resolve])
    end
  end
end
