# frozen_string_literal: true

require "rails_helper"
require "openssl"
require "ostruct"
require "timeout"

RSpec.describe "Commerce recovery regressions", type: :request, webmock: true do
  self.use_transactional_tests = false

  after { clean_commerce_data }

  def clean_commerce_data
    ActiveRecord::Base.connection.execute("TRUNCATE TABLE audit_logs, audit_write_failures, users, organizer_profiles, events, venues, site_settings, webhook_events RESTART IDENTITY CASCADE")
  end

  before do
    raise "Commerce recovery tests require test" unless Rails.env.test?
    clean_commerce_data
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeService).to receive(:verify_payment_context!).and_return(true)
    allow(StripeService).to receive(:cancel_payment_intent).and_return(OpenStruct.new(status: "canceled"))
    allow(StripeService).to receive(:publishable_key).and_return("pk_test_recovery_dummy")
    allow(Sentry).to receive(:capture_exception)
    allow(StripeCredentials).to receive(:webhook_secret).and_return("whsec_local_recovery_dummy")
    allow(Stripe::StripeClient).to receive(:new).and_raise("NO PROVIDER CLIENTS ALLOWED")
  end

  def checkout_fixture(pending: false, quantity: 2, live: false)
    event = create(:event, :published, starts_at: 5.days.from_now)
    type = create(:ticket_type, event: event, quantity_available: 10, quantity_sold: pending ? 0 : quantity)
    order = create(:order, event: event, status: pending ? :pending : :completed,
      expires_at: pending ? 10.minutes.from_now : nil, completed_at: pending ? nil : Time.current,
      total_cents: 5250, subtotal_cents: 5000, service_fee_cents: 250)
    item = create(:order_item, order: order, ticket_type: type, quantity: quantity,
      subtotal_cents: 5000, fee_cents: 250, organizer_proceeds_cents: 5000)
    payment = create(:payment, order: order, status: pending ? :pending : :succeeded,
      amount_cents: 5250, succeeded_at: pending ? nil : Time.current,
      provider_environment: live ? "live" : "test", provider_platform_account_id: "acct_local_recovery_dummy")
    if pending
      create(:inventory_hold, order: order, order_item: item, quantity: quantity)
    else
      quantity.times { create(:ticket, order: order, event: event, ticket_type: type, order_item: item) }
    end
    [order, payment, type]
  end

  def signed_webhook(type, object, id: "evt_recovery_#{SecureRandom.hex(8)}")
    payload = { id: id, type: type, created: Time.now.to_i, livemode: Payment.find_by(provider_payment_id: object[:payment_intent] || object[:id])&.provider_environment == "live", data: { object: object } }.to_json
    now = Time.now.to_i
    signature = OpenSSL::HMAC.hexdigest("SHA256", "whsec_local_recovery_dummy", "#{now}.#{payload}")
    post "/webhooks/stripe", params: payload, headers: { "CONTENT_TYPE"=>"application/json", "Stripe-Signature"=>"t=#{now},v1=#{signature}" }
    id
  end

  it "F01 retries a failed selected refund with its ticket, and replays both pending and successful outcomes" do
    order, payment, type = checkout_fixture(live: true)
    selected, other = order.tickets.order(:id).to_a
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_original", status: "failed"))
    original = Commerce::RefundCreator.call(order: order, tickets: [selected], idempotency_key: "selected-fail")
    expect(original.refund_tickets.sole.released_at).to be_present
    expect(selected.reload).to be_admission_allowed
    allow(StripeService).to receive(:retrieve_refund).and_return(OpenStruct.new(id: "re_original", status: "failed"))
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_replacement", status: "pending", amount: 2625, currency: "usd"))
    admin = create(:user, :admin)
    path = "/api/v1/admin/refund_reconciliation/refund/#{original.id}/retry"
    2.times do
      post path, headers: auth_headers(admin)
      expect(response).to have_http_status(:ok), response.body
    end
    replacement = order.refunds.find_by!(idempotency_key: "refund-reconciliation/#{original.id}")
    expect(replacement.refund_tickets.pluck(:ticket_id)).to eq([selected.id])
    expect(selected.reload).not_to be_admission_allowed
    expect(other.reload).to be_admission_allowed
    2.times do
      signed_webhook("refund.updated", { id: "re_replacement", payment_intent: payment.provider_payment_id,
        status: "succeeded", amount: 2625, currency: "usd" })
      expect(response).to have_http_status(:ok), response.body
    end
    post path, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(replacement.reload).to be_succeeded
    expect(order.reload.refund_amount_cents).to eq(2625)
    expect(order.refunds.succeeded.sum(:amount_cents)).to eq(2625)
    expect(selected.reload).to be_cancelled
    expect(type.reload.quantity_sold).to eq(1)
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(selected).not_to be_admission_allowed
    expect(other.reload).to be_admission_allowed
    expect { other.check_in! }.not_to raise_error
    expect(StripeService).to have_received(:refund_payment).twice
  end

  it "F01 allows retrying a failed replacement without losing its original selection" do
    order, = checkout_fixture
    selected, other = order.tickets.order(:id).to_a
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_fail_a", status: "failed"))
    original = Commerce::RefundCreator.call(order: order, tickets: [selected], idempotency_key: "twice-failed")
    allow(StripeService).to receive(:retrieve_refund).and_return(OpenStruct.new(status: "failed"))
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_fail_b", status: "failed"))
    admin = create(:user, :admin)
    failed = RefundReconciliationActions.call(type: "refund", id: original.id, action: "retry", actor: admin)
    expect(RefundReconciliationActions.call(type: "refund", id: original.id, action: "retry", actor: admin)).to eq(failed)
    expect(selected.reload).to be_admission_allowed
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_success_c", status: "succeeded"))
    result = RefundReconciliationActions.call(type: "refund", id: failed.id, action: "retry", actor: admin)
    expect(result).to be_succeeded
    expect(result.tickets).to contain_exactly(selected)
    expect(selected.reload).to be_cancelled
    expect(other.reload).to be_admission_allowed
    expect(StripeService).to have_received(:refund_payment).exactly(3).times
  end

  def late_capture(terminal)
    order, payment, type = checkout_fixture(pending: true)
    if terminal == :cancelled
      Commerce::OrderLifecycle.cancel!(order)
    else
      order.update!(expires_at: 1.minute.ago)
      order.inventory_holds.update_all(expires_at: 1.minute.ago) if terminal == :hold_expired
      Commerce::OrderLifecycle.expire!(order) unless terminal == :hold_expired
    end
    id = signed_webhook("payment_intent.succeeded", { id: payment.provider_payment_id, amount_received: 5250, currency: "usd" })
    expect(response).to have_http_status(:ok), response.body
    signed_webhook("payment_intent.succeeded", { id: payment.provider_payment_id, amount_received: 5250, currency: "usd" }, id: id)
    expect(response).to have_http_status(:ok)
    expect(order.reload.status).to eq(terminal == :cancelled ? "cancelled" : "expired")
    expect(payment.reload).to be_succeeded
    expect(order.tickets).to be_empty
    expect(type.reload.quantity_sold).to eq(0)
    [order, payment, type]
  end

  %i[expired cancelled hold_expired].each do |terminal|
    %i[app external].each do |recovery|
      it "F02 repays a #{terminal} late capture via #{recovery}, never fulfilling or releasing twice" do
        order, payment, type = late_capture(terminal)
        object = { id: "re_late", payment_intent: payment.provider_payment_id, amount: 5250, currency: "usd", status: "succeeded" }
        if recovery == :app
          allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(object))
          2.times do
            expect(Commerce::RefundCreator.call(order: order, payment: payment, idempotency_key: "late-repay")).to be_succeeded
          end
          expect(StripeService).to have_received(:refund_payment).once
        else
          signed_webhook("refund.updated", object)
          expect(response).to have_http_status(:ok), response.body
        end
        2.times do
          signed_webhook("charge.refunded", { id: "ch_late", payment_intent: payment.provider_payment_id,
            amount_refunded: 5250, currency: "usd", refunds: { data: [object] } }, id: "evt_late_refund")
          expect(response).to have_http_status(:ok), response.body
        end
        expect(order.refunds.succeeded.count).to eq(1)
        expect(order.refunds.joins(:refund_items).sum("refund_items.amount_cents")).to eq(5250)
        expect(order.reload).to have_attributes(status: "refunded", refund_amount_cents: 5250)
        expect(payment.reload).to be_refunded
        expect(order.reconciliation_exceptions.open.where(code: %w[late_payment_success_after_inventory_release late_payment_success_after_hold_expiry])).to be_empty
        expect(order.tickets).to be_empty
        expect(order.inventory_holds).to all(satisfy { |hold| hold.released? || hold.expired? })
        expect(type.reload.quantity_sold).to eq(0)
        expect(type.available_quantity).to eq(10)
        expect(WebhookEvent.find_by!(provider_event_id: "evt_late_refund")).to be_processed
      end
    end
  end

  it "does not grant the late-capture refund exception to an unrelated state or unresolved mismatch" do
    order, payment, = checkout_fixture(pending: true)
    payment.update!(status: :succeeded, succeeded_at: Time.current)
    expect { Commerce::RefundCreator.call(order: order, payment: payment) }.to raise_error(Commerce::RefundCreator::RefundError)
    order, payment, = late_capture(:cancelled)
    create(:reconciliation_exception, order: order, payment: payment, code: "payment_amount_mismatch")
    expect { Commerce::RefundCreator.call(order: order, payment: payment) }
      .to raise_error(Commerce::RefundCreator::RefundError, /finance review/)
  end

  it "A01 ingests unlinked signed external refund operations and an unexpanded charge exactly once" do
    order, payment, type = checkout_fixture(live: true)
    object = { id: "re_external", payment_intent: payment.provider_payment_id, amount: 5250, currency: "usd", status: "pending" }
    signed_webhook("refund.created", object)
    expect(response).to have_http_status(:ok), response.body
    expect(order.tickets.reload).to all(satisfy { |ticket| !ticket.admission_allowed? })
    2.times do
      signed_webhook("refund.updated", object.merge(status: "succeeded"))
      expect(response).to have_http_status(:ok)
    end
    signed_webhook("charge.refunded", { id: "ch_external", payment_intent: payment.provider_payment_id, amount_refunded: 5250, currency: "usd" })
    expect(response).to have_http_status(:ok)
    expect(order.refunds.succeeded.count).to eq(1)
    expect(order.reload.refund_amount_cents).to eq(5250)
    expect(payment.reload).to be_refunded
    expect(order.tickets.reload).to all(be_cancelled)
    expect(type.reload.quantity_sold).to eq(0)
    expect(RefundReconciliationQueue.new(event_id: order.event_id).entries).to be_empty
  end

  it "A01 exposes an aggregate-only gap and lets an admin retrieve verified operations without sending money" do
    order, payment, type = checkout_fixture
    signed_webhook("charge.refunded", { id: "ch_aggregate", payment_intent: payment.provider_payment_id, amount_refunded: 5250, currency: "usd" })
    expect(response).to have_http_status(:ok)
    expect(order.refunds).to be_empty
    issue = order.reconciliation_exceptions.open.find_by!(code: "refund_aggregate_requires_reconciliation")
    expect(OrganizationPayoutBalance.available_cents(order.event.organization)).to eq(0)
    expect(RefundReconciliationQueue.new(event_id: order.event_id).entries).to include(include(type: "exception", id: issue.id))
    allow(StripeService).to receive(:list_refunds).and_return([OpenStruct.new(id: "re_recovered", payment_intent: payment.provider_payment_id,
      amount: 5250, currency: "usd", status: "succeeded")])
    allow(StripeService).to receive(:refund_payment)
    admin = create(:user, :admin)
    2.times do
      post "/api/v1/admin/refund_reconciliation/exception/#{issue.id}/resync", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok), response.body
    end
    expect(issue.reload).to be_resolved
    expect(order.refunds.succeeded.count).to eq(1)
    expect(order.reload.refund_amount_cents).to eq(5250)
    expect(payment.reload).to be_refunded
    expect(order.tickets.reload).to all(be_cancelled)
    expect(type.reload.quantity_sold).to eq(0)
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "A01 preserves holds and refuses another payment's provider operation during admin recovery" do
    order, payment, = checkout_fixture
    issue = create(:reconciliation_exception, order: order, payment: payment,
      code: "refund_aggregate_requires_reconciliation", actual_amount_cents: 5250)
    allow(StripeService).to receive(:list_refunds).and_return([OpenStruct.new(id: "re_wrong", payment_intent: "pi_other",
      amount: 5250, currency: "usd", status: "succeeded")])
    post "/api/v1/admin/refund_reconciliation/exception/#{issue.id}/resync", headers: auth_headers(create(:user, :admin))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(order.refunds).to be_empty
    expect(issue.reload).to be_open
  end
  it "A01 rejects external-refund ingestion when payment account verification fails" do
    order, payment, = checkout_fixture
    allow(StripeService).to receive(:verify_payment_context!).and_raise(StripeService::PaymentError, "Wrong account")
    signed_webhook("refund.updated", { id: "re_wrong_context", payment_intent: payment.provider_payment_id,
      amount: 5250, currency: "usd", status: "succeeded" })
    expect(response).to have_http_status(:ok)
    expect(order.refunds).to be_empty
    expect(order.reconciliation_exceptions).to exist(code: "payment_context_mismatch")
    expect(order.tickets.reload).to all(be_issued)
  end

  it "A01 keeps invalid external operations actionable without booking an amount or returning a webhook 500" do
    order, payment, = checkout_fixture
    signed_webhook("refund.updated", { id: "re_wrong_currency", payment_intent: payment.provider_payment_id,
      amount: 5250, currency: "eur", status: "succeeded" })
    expect(response).to have_http_status(:ok)
    expect(order.refunds).to be_empty
    issue = order.reconciliation_exceptions.open.find_by!(code: "refund_operation_not_found")
    expect(RefundReconciliationQueue.new(event_id: order.event_id).entries).to include(include(type: "exception", id: issue.id))
    post "/api/v1/admin/refund_reconciliation/exception/#{issue.id}/resync", headers: auth_headers(create(:user))
    expect(response).to have_http_status(:forbidden)
  end

  def provider_operation(payment, id:, amount: 5250, status: "succeeded", key: nil)
    { id: id, payment_intent: payment.provider_payment_id, amount: amount,
      currency: "usd", status: status, metadata: key ? { hafapass_refund_key: key } : {} }
  end

  def reserve_operation(order, payment, amount: 5250, tickets: nil, id: "re_local")
    observation = provider_operation(payment, id: id, amount: amount, status: "pending")
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(observation))
    Commerce::RefundCreator.call(order: order, payment: payment, amount_cents: amount,
      tickets: tickets, idempotency_key: "reserved-local")
  end

  def admin_resync(record, type: "exception")
    @recovery_admin ||= create(:user, :admin)
    post "/api/v1/admin/refund_reconciliation/#{type}/#{record.id}/resync", headers: auth_headers(@recovery_admin)
    expect(response).to have_http_status(:ok), response.body
  end

  def observe_aggregate(payment, amount: 5250)
    signed_webhook("charge.refunded", { id: "ch_review", payment_intent: payment.provider_payment_id,
      amount_refunded: amount, currency: "usd" }, id: "evt_review_aggregate")
    expect(response).to have_http_status(:ok)
    payment.reconciliation_exceptions.open.find_by!(code: "refund_aggregate_requires_reconciliation")
  end

  [false, true].each do |reverse|
    it "R1-01 preserves an aggregate gap through pending failure and recovers both list orders (reverse=#{reverse})" do
      order, payment, type = checkout_fixture
      local = reserve_operation(order, payment)
      issue = observe_aggregate(payment)
      expect(local.reload).to be_pending
      expect(order.tickets.reload).to all(satisfy { |ticket| !ticket.admission_allowed? })
      failed = provider_operation(payment, id: "re_local", status: "failed")
      allow(StripeService).to receive(:retrieve_refund).and_return(OpenStruct.new(failed))
      admin_resync(local, type: "refund")
      expect(local.reload).to be_failed
      expect(issue.reload).to be_open
      expect(RefundReconciliationQueue.new(event_id: order.event_id).entries).to include(include(type: "exception", id: issue.id))
      external = provider_operation(payment, id: "re_external")
      list = [external, failed]
      list.reverse! if reverse
      allow(StripeService).to receive(:list_refunds).and_return(list.map { |entry| OpenStruct.new(entry) })
      2.times { admin_resync(issue) }
      observe_aggregate_replay(payment)
      expect(issue.reload).to be_resolved
      expect(order.refunds.succeeded.pluck(:provider_refund_id)).to eq(["re_external"])
      expect(order.reload.refund_amount_cents).to eq(5250)
      expect(order.tickets.reload).to all(be_cancelled)
      expect(type.reload.quantity_sold).to eq(0)
      expect(StripeService).to have_received(:refund_payment).once
    end
  end

  def observe_aggregate_replay(payment)
    signed_webhook("charge.refunded", { id: "ch_review", payment_intent: payment.provider_payment_id,
      amount_refunded: 5250, currency: "usd" }, id: "evt_review_aggregate")
    expect(response).to have_http_status(:ok)
  end

  %i[webhook admin].each do |channel|
    [false, true].each do |reverse|
      it "R1-02 books distinct IDs with copied metadata via #{channel} in both orders (reverse=#{reverse})" do
        order, payment, type = checkout_fixture
        selected = order.tickets.order(:id).first
        local = reserve_operation(order, payment, amount: 2625, tickets: [selected], id: "re_A")
        issue = observe_aggregate(payment)
        objects = %w[re_B re_A].map { |id| provider_operation(payment, id: id, amount: 2625, key: local.idempotency_key) }
        objects.reverse! if reverse
        allow(StripeService).to receive(:list_refunds).and_return(objects.map { |entry| OpenStruct.new(entry) })
        if channel == :webhook
          objects.each do |object|
            2.times do
              signed_webhook("refund.updated", object)
              expect(response).to have_http_status(:ok), response.body
              expect(local.reload.provider_refund_id).to eq("re_A")
              expect(local.tickets).to contain_exactly(selected)
            end
          end
        end
        2.times { admin_resync(issue) }
        expect(local.reload).to have_attributes(provider_refund_id: "re_A", status: "succeeded")
        expect(local.tickets).to contain_exactly(selected)
        expect(order.refunds.succeeded.pluck(:provider_refund_id)).to match_array(%w[re_A re_B])
        expect(order.reload.refund_amount_cents).to eq(5250)
        expect(payment.reload).to be_refunded
        expect(order.tickets.reload).to all(be_cancelled)
        expect(type.reload.quantity_sold).to eq(0)
        expect(issue.reload).to be_resolved
        expect(StripeService).to have_received(:refund_payment).once
      end
    end
  end

  %i[webhook admin].each do |channel|
    it "R1-02 still binds a verified nil-ID lost-response reservation through #{channel}" do
      order, payment, = checkout_fixture
      allow(StripeService).to receive(:refund_payment).and_raise(Stripe::APIConnectionError.new("lost local response"))
      expect { Commerce::RefundCreator.call(order: order, payment: payment, idempotency_key: "lost-response") }
        .to raise_error(Commerce::RefundCreator::RefundError, /unknown/)
      local = order.refunds.sole
      expect(local.provider_refund_id).to be_nil
      object = provider_operation(payment, id: "re_recovered_response", key: local.idempotency_key)
      if channel == :webhook
        signed_webhook("refund.updated", object)
        expect(response).to have_http_status(:ok)
      else
        issue = observe_aggregate(payment)
        allow(StripeService).to receive(:list_refunds).and_return([OpenStruct.new(object)])
        admin_resync(issue)
      end
      expect(local.reload).to have_attributes(status: "succeeded", provider_refund_id: object[:id])
      expect(order.refunds.count).to eq(1)
      expect(StripeService).to have_received(:refund_payment).once
    end
  end

  %w[failed canceled].each do |historical_status|
    [2625, 5250].each do |returned_amount|
      [false, true].each do |reverse|
        it "R1-03 recovers #{returned_amount} with unknown historical #{historical_status} in both list orders (reverse=#{reverse})" do
          order, payment, type = checkout_fixture
          issue = observe_aggregate(payment, amount: returned_amount)
          success = provider_operation(payment, id: "re_returned", amount: returned_amount)
          historical = provider_operation(payment, id: "re_historical", status: historical_status)
          list = [success, historical]
          list.reverse! if reverse
          allow(StripeService).to receive(:list_refunds).and_return(list.map { |entry| OpenStruct.new(entry) })
          allow(StripeService).to receive(:refund_payment)
          2.times { admin_resync(issue) }
          expect(issue.reload).to be_resolved
          expect(order.refunds.pluck(:provider_refund_id)).to eq(["re_returned"])
          expect(order.reload.refund_amount_cents).to eq(returned_amount)
          expect(type.reload.quantity_sold).to eq(returned_amount == 5250 ? 0 : 2)
          expect(AuditLog.where(auditable: payment, action: "refund.external_observed").count).to eq(1)
          expect(StripeService).not_to have_received(:refund_payment)
        end
      end
    end
  end

  it "R1-03 reconciles a verified known failure before reserving an external return regardless of newest-first listing" do
    order, payment, = checkout_fixture
    local = reserve_operation(order, payment)
    # This persisted observation predates the fix for aggregate suppression.
    issue = create(:reconciliation_exception, order: order, payment: payment,
      code: "refund_aggregate_requires_reconciliation", actual_amount_cents: 5250)
    list = [provider_operation(payment, id: "re_external"), provider_operation(payment, id: "re_local", status: "failed")]
    allow(StripeService).to receive(:list_refunds).and_return(list.map { |entry| OpenStruct.new(entry) })
    2.times { admin_resync(issue) }
    expect(local.reload).to be_failed
    expect(order.refunds.succeeded.sole.provider_refund_id).to eq("re_external")
    expect(issue.reload).to be_resolved
  end

  it "R1-03 never discards an unidentified pending reservation to fit an external operation" do
    order, payment, = checkout_fixture
    allow(StripeService).to receive(:refund_payment).and_raise(Stripe::APIConnectionError.new("lost local response"))
    expect { Commerce::RefundCreator.call(order: order, payment: payment, idempotency_key: "unknown-local") }
      .to raise_error(Commerce::RefundCreator::RefundError)
    local = order.refunds.sole
    issue = observe_aggregate(payment)
    allow(StripeService).to receive(:list_refunds).and_return([OpenStruct.new(provider_operation(payment, id: "re_unrelated_external"))])
    2.times do
      post "/api/v1/admin/refund_reconciliation/exception/#{issue.id}/resync", headers: auth_headers(create(:user, :admin))
      expect(response).to have_http_status(:unprocessable_entity)
    end
    expect(local.reload).to be_pending
    expect(local.provider_refund_id).to be_nil
    expect(order.refunds.succeeded).to be_empty
    expect(issue.reload).to be_open
    expect(order.tickets.reload).to all(satisfy { |ticket| !ticket.admission_allowed? })
    expect(OrganizationPayoutBalance.available_cents(order.event.organization)).to eq(0)
  end

  %i[charge direct legacy_charge].each do |origin|
    it "R1-04 matches #{origin} exceptions by verified operation identity after recovering the reservation" do
      order, payment, type = checkout_fixture
      local = reserve_operation(order, payment, amount: 2625)
      external = provider_operation(payment, id: "re_embedded")
      if origin == :direct
        event_id = signed_webhook("refund.updated", external)
      else
        event_id = signed_webhook("charge.refunded", { id: "ch_embedded", payment_intent: payment.provider_payment_id,
          amount_refunded: 5250, currency: "usd", refunds: { data: [external] } })
      end
      expect(response).to have_http_status(:ok)
      issue = order.reconciliation_exceptions.open.find_by!(code: "refund_operation_not_found")
      if origin == :legacy_charge
        issue.update!(details: { error: "old exception without operation identity" })
      else
        expect(issue.details).to include("provider_refund_id" => "re_embedded", "amount_cents" => 5250,
          "currency" => "usd", "provider_payment_id" => payment.provider_payment_id)
      end
      unrelated = create(:reconciliation_exception, order: order, payment: payment, code: "payment_amount_mismatch")
      failed = provider_operation(payment, id: "re_local", amount: 2625, status: "failed")
      allow(StripeService).to receive(:retrieve_refund).and_return(OpenStruct.new(failed))
      admin_resync(local, type: "refund")
      allow(StripeService).to receive(:list_refunds).and_return([external, failed].map { |entry| OpenStruct.new(entry) })
      2.times { admin_resync(issue) }
      expect(issue.reload).to be_resolved
      expect(unrelated.reload).to be_open
      expect(order.reconciliation_exceptions.open.where(code: "refund_aggregate_requires_reconciliation")).to be_empty
      expect(order.refunds.succeeded.sole.provider_refund_id).to eq("re_embedded")
      expect(order.tickets.reload).to all(be_cancelled)
      expect(type.reload.quantity_sold).to eq(0)
      receipt = WebhookEvent.find_by!(provider_event_id: event_id)
      StripeWebhookProcessor.call(event: Stripe::Event.construct_from(receipt.payload), payload: receipt.payload)
      expect(order.refunds.succeeded.count).to eq(1)
      expect(StripeService).to have_received(:refund_payment).once
    end
  end

  it "R1-04 resolves only the matching operation in a multi-refund charge and keeps ambiguous legacy evidence open" do
    order, payment, = checkout_fixture
    local = reserve_operation(order, payment, amount: 2625)
    valid = provider_operation(payment, id: "re_good_embedded")
    invalid = provider_operation(payment, id: "re_bad_embedded", amount: 100).merge(currency: "eur")
    event_id = signed_webhook("charge.refunded", { id: "ch_many", payment_intent: payment.provider_payment_id,
      amount_refunded: 5250, currency: "usd", refunds: { data: [valid, invalid] } })
    expect(response).to have_http_status(:ok)
    good_issue = order.reconciliation_exceptions.open.where(code: "refund_operation_not_found")
      .find { |entry| entry.details["provider_refund_id"] == valid[:id] }
    bad_issue = order.reconciliation_exceptions.open.where(code: "refund_operation_not_found")
      .find { |entry| entry.details["provider_refund_id"] == invalid[:id] }
    expect(good_issue).to be_present
    expect(bad_issue).to be_present
    receipt = WebhookEvent.find_by!(provider_event_id: event_id)
    legacy = create(:reconciliation_exception, order: order, payment: payment, webhook_event: receipt,
      code: "refund_operation_not_found", details: { error: "ambiguous old embedded failure" })
    failed = provider_operation(payment, id: "re_local", amount: 2625, status: "failed")
    allow(StripeService).to receive(:list_refunds).and_return([valid, failed].map { |entry| OpenStruct.new(entry) })
    2.times { admin_resync(good_issue) }
    expect(good_issue.reload).to be_resolved
    expect(bad_issue.reload).to be_open
    expect(legacy.reload).to be_open
    expect(local.reload).to be_failed
    expect(order.refunds.succeeded.sole.provider_refund_id).to eq(valid[:id])
    expect(order.reload.refund_amount_cents).to eq(5250)
    expect(OrganizationPayoutBalance.available_cents(order.event.organization)).to eq(0)
  end

  %w[failed canceled].each do |status|
    it "R1-03 acknowledges historical external #{status} callbacks after a full return without reserving money" do
      order, payment, = checkout_fixture
      signed_webhook("refund.updated", provider_operation(payment, id: "re_succeeded"))
      expect(response).to have_http_status(:ok)
      2.times do
        signed_webhook("refund.#{status == 'failed' ? 'failed' : 'updated'}",
          provider_operation(payment, id: "re_historical", status: status))
        expect(response).to have_http_status(:ok), response.body
      end
      expect(order.reload).to be_refunded
      expect(order.refunds.count).to eq(1)
      expect(payment.refunds.succeeded.sum(:amount_cents)).to eq(5250)
      expect(AuditLog.where(auditable: payment, action: "refund.external_observed").count).to eq(1)
    end
  end

  it "R1-03 keeps a known terminal-conflict hold while closing a different verified aggregate gap" do
    order, payment, = checkout_fixture
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_failed_known", status: "failed"))
    failed = Commerce::RefundCreator.call(order: order, payment: payment, amount_cents: 2625, idempotency_key: "failed-known")
    issue = observe_aggregate(payment)
    list = [provider_operation(payment, id: "re_new_success"),
      provider_operation(payment, id: "re_failed_known", amount: 2625, status: "succeeded")]
    allow(StripeService).to receive(:list_refunds).and_return(list.map { |entry| OpenStruct.new(entry) })
    2.times { admin_resync(issue) }
    expect(failed.reload).to be_failed
    expect(issue.reload).to be_resolved
    expect(order.refunds.succeeded.sole.provider_refund_id).to eq("re_new_success")
    expect(order.reconciliation_exceptions.open).to exist(code: "refund_terminal_status_conflict")
    expect(OrganizationPayoutBalance.available_cents(order.event.organization)).to eq(0)
  end

  it "R1-02 validates an embedded payment identity before metadata can bind a known reservation" do
    order, payment, type = checkout_fixture
    local = reserve_operation(order, payment, amount: 2625, tickets: [order.tickets.first])
    object = provider_operation(payment, id: "re_local", amount: 2625, key: local.idempotency_key)
      .merge(payment_intent: "pi_other_payment")
    signed_webhook("charge.refunded", { id: "ch_wrong_embedded_context", payment_intent: payment.provider_payment_id,
      amount_refunded: 2625, currency: "usd", refunds: { data: [object] } })
    expect(response).to have_http_status(:ok)
    expect(local.reload).to be_pending
    expect(order.refunds.succeeded).to be_empty
    expect(order.reload.refund_amount_cents).to eq(0)
    expect(type.reload.quantity_sold).to eq(2)
    issue = order.reconciliation_exceptions.open.find_by!(code: "refund_operation_not_found")
    expect(issue.details["provider_payment_id"]).to eq("pi_other_payment")
    expect(OrganizationPayoutBalance.available_cents(order.event.organization)).to eq(0)
  end

  [["succeeded", "payment_intent.succeeded"], ["canceled", "payment_intent.succeeded"],
    ["succeeded", "payment_intent.canceled"]].each do |recovery_state, webhook_type|
    it "F09 serializes #{recovery_state} recovery against signed #{webhook_type} without a request 500" do
      order, payment, type = checkout_fixture(pending: true)
      recovery_order = Order.find(order.id)
      event_locked, recovery_attempting, outcomes = Queue.new, Queue.new, Queue.new
      allow(StripeService).to receive(:retrieve_payment_intent) do
        Timeout.timeout(5) { event_locked.pop }
        Thread.current[:provider_retrieved] = true
        OpenStruct.new(id: payment.provider_payment_id, amount: 5250, amount_received: 5250,
          currency: "usd", livemode: false, status: recovery_state)
      end
      allow(Commerce::OrderLifecycle).to receive(:lock_event_context!).and_wrap_original do |original, candidate|
        if Thread.current[:commerce_worker] == :recovery && Thread.current[:provider_retrieved]
          recovery_attempting << true
        end
        original.call(candidate)
        if Thread.current[:commerce_worker] == :webhook
          event_locked << true
          Timeout.timeout(5) { recovery_attempting.pop }
        end
      end
      workers = [Thread.new do
        Thread.current[:commerce_worker] = :recovery
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET lock_timeout = '8s'")
          begin
            result = Commerce::PaymentRecovery.call(order: recovery_order)
            outcomes << [:recovery, result.class.name]
          rescue StandardError => e
            outcomes << [:recovery, e]
          ensure
            connection.execute("RESET lock_timeout")
          end
        end
      end, Thread.new do
        Thread.current[:commerce_worker] = :webhook
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET lock_timeout = '8s'")
          begin
            signed_webhook(webhook_type, { id: payment.provider_payment_id, amount_received: 5250, currency: "usd" }, id: "evt_race")
            outcomes << [:webhook, response.status]
          rescue StandardError => e
            outcomes << [:webhook, e]
          ensure
            connection.execute("RESET lock_timeout")
          end
        end
      end]
      Timeout.timeout(12) { workers.each(&:join) }
      results = 2.times.map { outcomes.pop }
      expect(results).to contain_exactly([:recovery, "Commerce::PaymentRecovery::Result"], [:webhook, 200])
      expect(WebhookEvent.find_by!(provider_event_id: "evt_race")).to have_attributes(status: "processed", attempts: 1)
      if webhook_type == "payment_intent.succeeded"
        expect(order.reload).to be_completed
        expect(order.tickets.count).to eq(2)
        expect(type.reload.quantity_sold).to eq(2)
        expect(order.inventory_holds).to all(be_consumed)
        expect(AuditLog.where(auditable: order, action: "order.completed").count).to eq(1)
      else
        expect(order.reload).to be_cancelled
        expect(order.tickets).to be_empty
        expect(type.reload.quantity_sold).to eq(0)
      end
      allow(Commerce::OrderLifecycle).to receive(:lock_event_context!).and_call_original
      signed_webhook(webhook_type, { id: payment.provider_payment_id, amount_received: 5250, currency: "usd" }, id: "evt_race")
      expect(response).to have_http_status(:ok)
    ensure
      workers&.each { |worker| worker.kill if worker.alive? }
      workers&.each(&:join)
    end
  end
end
