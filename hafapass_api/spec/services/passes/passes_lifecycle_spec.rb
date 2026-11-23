# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Multi-night passes lifecycle, refunds, disputes, storm reschedules, retention & exports", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:owner) { create(:user) }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:org) { profile.organization }
  let(:owner_headers) { auth_headers(owner).merge("X-Organization-Id" => org.id.to_s) }

  let(:pass_event) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "FD Tourney Pass", max_capacity: 100, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
  end
  let(:night_1) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "Night 1", max_capacity: 20, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
  end
  let(:night_2) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "Night 2", max_capacity: 20, starts_at: 3.days.from_now, ends_at: 3.days.from_now + 3.hours)
  end
  let(:night_3) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "Night 3", max_capacity: 20, starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
  end
  let(:pass_tt) do
    create(:ticket_type, event: pass_event, name: "Season Pass", price_cents: 5000, quantity_available: 50)
  end
  let(:free_pass_tt) do
    create(:ticket_type, event: pass_event, name: "VIP Comp Pass", price_cents: 0, quantity_available: 50)
  end
  let(:night_1_tt) do
    create(:ticket_type, event: night_1, name: "Night 1 GA", price_cents: 1000, quantity_available: 20)
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent) do |order, **|
      OpenStruct.new(
        id: "pi_slice2a2_#{order.id}",
        client_secret: "cs_slice2a2_#{order.id}",
        allowed_payment_method_types: ["card"],
        payment_method_types: ["card"]
      )
    end
    allow(StripeService).to receive(:refund_payment) do |_pi, amount_cents:, **|
      OpenStruct.new(id: "re_slice2a2_#{SecureRandom.hex(6)}", status: "succeeded", amount: amount_cents, currency: "usd")
    end
    allow(StripeService).to receive(:verify_payment_context!).and_return(true)
  end

  def link_nights(ticket_type, events)
    events.each_with_index do |ev, idx|
      TicketTypeIncludedEvent.create!(ticket_type: ticket_type, included_event: ev, position: idx)
    end
    ticket_type.reload
  end

  def create_paid_pass_order(ticket_type: pass_tt, quantity: 1, buyer: nil, email: "pass-buyer@example.com", name: "Pass Fan")
    checkout = Commerce::OrderCreator.call(
      event: pass_event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: quantity }],
      buyer_email: buyer&.email || email,
      buyer_name: name,
      user: buyer,
      payment_required: true
    )
    Commerce::OrderLifecycle.complete!(
      checkout.order,
      payment: checkout.payment,
      provider_amount_cents: checkout.payment.amount_cents,
      provider_currency: checkout.payment.currency
    )
    [checkout.order.reload, checkout.payment.reload]
  end

  def create_free_pass_order(ticket_type: free_pass_tt, quantity: 1, buyer: nil, email: "free-pass@example.com", name: "Free Fan")
    Commerce::OrderCreator.call(
      event: pass_event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: quantity }],
      buyer_email: buyer&.email || email,
      buyer_name: name,
      user: buyer,
      payment_required: false
    ).order.reload
  end

  describe "1. Pass Refunds & Lost Disputes" do
    before { link_nights(pass_tt, [night_1, night_2, night_3]) }

    it "supports parent ticket-selected refund on an unused pass, bumping scan versions and releasing parent inventory once" do
      order, payment = create_paid_pass_order(quantity: 2)
      parents = order.tickets.where(parent_ticket_id: nil).order(:id).to_a
      parent1, parent2 = parents
      p1_children = parent1.child_tickets.order(:id).to_a
      p2_children = parent2.child_tickets.order(:id).to_a

      expect(pass_tt.reload.quantity_sold).to eq(2)
      p1_versions_before = [parent1, *p1_children].map(&:scan_credential_version)
      expected_refund_cents = parent1.refundable_cents
      expect(order.service_fee_cents).to be > 0
      expect(expected_refund_cents).to eq(order.order_items.sole.unit_price_cents + (order.service_fee_cents / 2))
      expect(expected_refund_cents).to eq(order.total_cents / 2)

      refund = Commerce::RefundCreator.call(
        order: order,
        tickets: [parent1],
        reason: "requested_by_customer",
        requested_by: owner,
        idempotency_key: "unused-pass-parent-1"
      )

      expect(refund).to be_succeeded
      expect(refund.amount_cents).to eq(expected_refund_cents)
      expect(StripeService).to have_received(:refund_payment).with(
        payment.provider_payment_id,
        hash_including(amount_cents: expected_refund_cents)
      )
      expect(order.reload).to be_partially_refunded
      expect(order.refunded_cents).to eq(expected_refund_cents)
      expect(pass_tt.reload.quantity_sold).to eq(1)

      expect(parent1.reload).to be_cancelled
      expect(p1_children.map { |t| t.reload.status }).to all(eq("cancelled"))
      expect([parent1, *p1_children].map(&:scan_credential_version)).to eq(p1_versions_before.map { |v| v + 1 })

      # Second pass on the same order stays intact
      expect(parent2.reload).to be_issued
      expect(p2_children.map { |t| t.reload.status }).to all(eq("issued"))
    end

    it "rejects direct child selection and refuses buyer/organizer ticket-selected refunds on partially used passes" do
      buyer = create(:user, :attendee, email: "used-buyer@example.com")
      order, _payment = create_paid_pass_order(buyer: buyer)
      parent = order.tickets.find_by!(parent_ticket_id: nil)
      child1 = order.tickets.find_by!(event: night_1)
      child2 = order.tickets.find_by!(event: night_2)

      # Direct child selection stays rejected
      expect do
        Commerce::RefundCreator.call(order: order, tickets: [child1], reason: "requested_by_customer", requested_by: owner)
      end.to raise_error(Commerce::RefundCreator::RefundError, "Refund the parent pass instead of a single night")

      # Admit Night 1 child (even if later undone, previously_admitted? stays true!)
      child1.check_in!
      child1.reverse_check_in!
      expect(child1.reload).to be_issued
      expect(child1).to be_previously_admitted

      # Organizer / direct ticket-selected refund refused
      expect do
        Commerce::RefundCreator.call(
          order: order,
          tickets: [parent],
          reason: "requested_by_customer",
          requested_by: owner,
          organizer_initiated: true,
          idempotency_key: "org-used-pass-parent"
        )
      end.to raise_error(
        Commerce::RefundCreator::RefundError,
        "Pass already used on one or more nights. Choose a custom amount to return money."
      )

      # Buyer self-serve cancel_ticket on postponed pass event also refused with 422
      EventLifecycle.call(event: pass_event, action: :postpone, actor: owner, reason: "Typhoon watch")
      post "/api/v1/orders/#{order.id}/tickets/#{parent.id}/cancel",
        headers: auth_headers(buyer).merge("Idempotency-Key" => "buyer-used-pass-parent")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq(
        "Pass has already been used on one or more nights; use an organizer custom-amount refund or contact support"
      )

      # Nothing was cancelled or released
      expect(parent.reload).to be_issued
      expect(child2.reload).to be_issued
      expect(pass_tt.reload.quantity_sold).to eq(1)
    end

    it "retains parent inventory with ONE grouped ReconciliationException and cancels unadmitted children on full-order refund" do
      order, _payment = create_paid_pass_order
      parent = order.tickets.find_by!(parent_ticket_id: nil)
      child1 = order.tickets.find_by!(event: night_1)
      child2 = order.tickets.find_by!(event: night_2)
      child3 = order.tickets.find_by!(event: night_3)

      child1.check_in!
      child2.check_in!
      child2.reverse_check_in! # Undone check-in still counts as previously_admitted?
      child3_version_before = child3.scan_credential_version

      expect(Commerce::FinancialReversalInventory).to receive(:call).once.and_call_original

      refund = Commerce::RefundCreator.call(
        order: order,
        reason: "requested_by_customer",
        requested_by: owner,
        idempotency_key: "full-order-used-pass"
      )

      expect(refund).to be_succeeded
      expect(order.reload).to be_refunded
      # Sold unit stays retained on pass ticket type (never released back for resale!)
      expect(pass_tt.reload.quantity_sold).to eq(1)
      expect(parent.reload).to be_issued
      expect(parent).to be_inventory_retained

      # Admitted children stay retained (not cancelled), unadmitted Night 3 child is cancelled + credential bumped
      expect(child1.reload).to be_checked_in
      expect(child2.reload).to be_issued
      expect(child2.admission_block_reason).to eq("inventory_retained")
      expect(child2).not_to be_admission_allowed
      expect(child3.reload).to be_cancelled
      expect(child3.scan_credential_version).to eq(child3_version_before + 1)

      # ONE grouped ReconciliationException linked to parent's TicketInventoryRetention
      exceptions = ReconciliationException.where(order: order, code: "admitted_inventory_retained")
      expect(exceptions.count).to eq(1)
      exception = exceptions.sole
      expect(exception.details).to include(
        "parent_ticket_id" => parent.id,
        "admitted_child_ticket_ids" => contain_exactly(child1.id, child2.id),
        "refund_id" => refund.id
      )
      expect(TicketInventoryRetention.where(ticket_id: order.tickets.select(:id)).count).to eq(1)
      expect(parent.inventory_retention.reconciliation_exception_id).to eq(exception.id)

      # Night 2 counts & manifest reflect child2 blocked as inventory_retained
      expect(Admissions::Counts.call(event: night_2)).to include(total: 1, issued: 1, eligible_unadmitted: 0)
      manifest2 = Admissions::ManifestBuilder.call(event: night_2, actor: owner)
      expect(manifest2.payload.fetch("tickets").sole["state"]).to eq("inventory_retained")

      # Cancelled Night 3 child stays distinct from retained Night 2 in both OrderPresenter and TicketsController
      guest_token = GuestOrderAccess.issue!(order)
      get "/api/v1/orders/#{order.id}", headers: { "X-Guest-Order-Token" => guest_token }
      expect(response).to have_http_status(:ok)
      presented_children = response.parsed_body.fetch("tickets").sole.fetch("child_tickets").index_by { |c| c["id"] }
      expect(presented_children.fetch(child2.id)).to include(
        "status" => "issued",
        "admission_allowed" => false,
        "admission_block_reason" => "Refunded or disputed admission requires organizer review"
      )
      expect(presented_children.fetch(child3.id)).to include(
        "status" => "cancelled",
        "admission_allowed" => false,
        "admission_block_reason" => nil
      )

      get "/api/v1/tickets/#{parent.display_credential}", headers: { "X-Guest-Order-Token" => guest_token }
      expect(response).to have_http_status(:ok)
      parent_children = response.parsed_body.fetch("child_tickets").index_by { |c| c["id"] }
      expect(parent_children.fetch(child2.id)["admission_block_reason"]).to eq(
        "Refunded or disputed admission requires organizer review"
      )
      expect(parent_children.fetch(child3.id)["admission_block_reason"]).to be_nil

      get "/api/v1/tickets/#{child3.display_credential}", headers: { "X-Guest-Order-Token" => guest_token }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("status" => "cancelled", "admission_block_reason" => nil)

      get "/api/v1/tickets/#{child2.display_credential}", headers: { "X-Guest-Order-Token" => guest_token }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "status" => "issued",
        "admission_block_reason" => "Refunded or disputed admission requires organizer review"
      )
    end

    it "handles a lost dispute on a partially used pass with ONE grouped ReconciliationException and cancels unadmitted children" do
      order, payment = create_paid_pass_order
      parent = order.tickets.find_by!(parent_ticket_id: nil)
      child1 = order.tickets.find_by!(event: night_1)
      child2 = order.tickets.find_by!(event: night_2)
      child3 = order.tickets.find_by!(event: night_3)

      child1.check_in!
      child2_version = child2.scan_credential_version
      child3_version = child3.scan_credential_version

      dispute_event = OpenStruct.new(
        id: "evt_dispute_pass_lost",
        type: "charge.dispute.closed",
        created: Time.current.to_i,
        data: OpenStruct.new(
          object: {
            "id" => "dp_pass_lost_1",
            "payment_intent" => payment.provider_payment_id,
            "amount" => order.total_cents,
            "currency" => order.currency,
            "reason" => "fraudulent",
            "status" => "lost"
          }
        )
      )
      expect(Commerce::FinancialReversalInventory).to receive(:call).once.and_call_original
      StripeWebhookProcessor.call(event: dispute_event, payload: { "id" => dispute_event.id, "type" => dispute_event.type })

      expect(pass_tt.reload.quantity_sold).to eq(1)
      expect(parent.reload).to be_inventory_retained
      expect(child1.reload).to be_checked_in
      expect(child2.reload).to be_cancelled
      expect(child3.reload).to be_cancelled
      expect(child2.scan_credential_version).to eq(child2_version + 1)
      expect(child3.scan_credential_version).to eq(child3_version + 1)

      exceptions = ReconciliationException.where(order: order, code: "admitted_inventory_retained")
      expect(exceptions.count).to eq(1)
      expect(exceptions.sole.details).to include(
        "parent_ticket_id" => parent.id,
        "admitted_child_ticket_ids" => [child1.id]
      )
      expect(TicketInventoryRetention.where(ticket_id: order.tickets.select(:id)).count).to eq(1)
    end

    it "re-raises LockSetChanged immediately without retrying when inside an active application transaction" do
      attempts = 0
      expect do
        Order.transaction do
          Passes::Locking.with_lock_retry do
            attempts += 1
            raise Passes::Locking::LockSetChanged, "changed inside nested transaction"
          end
        end
      end.to raise_error(Passes::Locking::LockSetChanged)
      expect(attempts).to eq(1)
    end
  end

  describe "Organizer ticket selections" do
    let(:headers) { owner_headers.merge("Idempotency-Key" => "organizer-pass-selection") }

    it "cancels an unused paid pass atomically and blocks any pass that has been scanned" do
      link_nights(pass_tt, [night_1, night_2])
      order, _payment = create_paid_pass_order(quantity: 2)
      unused, used = order.tickets.where(parent_ticket_id: nil).order(:id)
      used.child_tickets.first.check_in!
      path = "/api/v1/organizer/events/#{pass_event.id}/orders/#{order.id}"

      get "#{path}/refund_options", headers: headers
      expect(response).to have_http_status(:ok), response.body
      options = response.parsed_body.fetch("tickets").index_by { |ticket| ticket.fetch("id") }
      expect(options.fetch(unused.id)).to include("is_pass_parent" => true, "included_nights_count" => 2, "selectable" => true)
      expect(options.fetch(used.id)).to include("selectable" => false,
        "unavailable_reason" => "Pass already used on one or more nights. Choose a custom amount to return money.")
      expect(options.fetch(unused.child_tickets.first.id)).to include("selectable" => false,
        "unavailable_reason" => "Choose the multi-night pass to cancel its nights")

      post "#{path}/refund", params: { ticket_ids: [unused.id, used.id] }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(StripeService).not_to have_received(:refund_payment)

      expect do
        post "#{path}/refund", params: { ticket_ids: [unused.id] }, headers: headers, as: :json
      end.to change { pass_tt.reload.quantity_sold }.from(2).to(1)
        .and change { EventCapacity.remaining_for(night_2) }.by(1)
      expect(response).to have_http_status(:created), response.body
      expect(unused.reload).to be_cancelled
      expect(unused.child_tickets.pluck(:status)).to all(eq("cancelled"))
      expect(used.reload).to be_issued
      expect(used.child_tickets.pluck(:status)).to contain_exactly("checked_in", "issued")
    end

    it "releases an unused free pass and its nights while keeping the remaining pass active" do
      link_nights(free_pass_tt, [night_1, night_2])
      order = create_free_pass_order(quantity: 2)
      selected, retained = order.tickets.where(parent_ticket_id: nil).order(:id)

      expect do
        post "/api/v1/organizer/events/#{pass_event.id}/orders/#{order.id}/refund",
          params: { ticket_ids: [selected.id] }, headers: headers, as: :json
      end.to change { free_pass_tt.reload.quantity_sold }.from(2).to(1)
        .and change { EventCapacity.remaining_for(night_2) }.by(1)
      expect(response).to have_http_status(:created), response.body
      expect(selected.reload).to be_cancelled
      expect(selected.child_tickets.pluck(:status)).to eq(%w[cancelled cancelled])
      expect(retained.child_tickets.to_a).to all(be_admission_allowed)
      expect(StripeService).not_to have_received(:refund_payment)
    end
  end

  describe "2. Free $0 Pass Cancellation Cascade" do
    before { link_nights(free_pass_tt, [night_1, night_2]) }

    it "cascades cancellation from parent to children, releases inventory once, and transitions order to cancelled" do
      buyer = create(:user, :attendee, email: "free-cancel@example.com")
      order = create_free_pass_order(buyer: buyer, quantity: 2)
      parent1, parent2 = order.tickets.where(parent_ticket_id: nil).order(:id).to_a
      p1_children = parent1.child_tickets.order(:id).to_a
      p1_versions = [parent1, *p1_children].map(&:scan_credential_version)

      expect(free_pass_tt.reload.quantity_sold).to eq(2)

      # Child direct cancel rejected with 422
      post "/api/v1/orders/#{order.id}/tickets/#{p1_children.first.id}/cancel",
        headers: auth_headers(buyer)
      expect(response).to have_http_status(:unprocessable_entity)

      # Cancel first free pass -> cancels parent1 + children1, releases 1 unit, order stays completed
      post "/api/v1/orders/#{order.id}/tickets/#{parent1.id}/cancel",
        headers: auth_headers(buyer)
      expect(response).to have_http_status(:ok)
      expect(free_pass_tt.reload.quantity_sold).to eq(1)
      expect(parent1.reload).to be_cancelled
      expect(p1_children.map { |t| t.reload.status }).to all(eq("cancelled"))
      expect([parent1, *p1_children].map(&:scan_credential_version)).to eq(p1_versions.map { |v| v + 1 })
      expect(order.reload).to be_completed

      # Cancel second free pass -> transitions order to cancelled
      post "/api/v1/orders/#{order.id}/tickets/#{parent2.id}/cancel",
        headers: auth_headers(buyer)
      expect(response).to have_http_status(:ok)
      expect(free_pass_tt.reload.quantity_sold).to eq(0)
      expect(order.reload).to be_cancelled
      expect(order.tickets.pluck(:status).uniq).to eq(["cancelled"])
    end

    it "rejects cancelling a free pass when any child night was previously admitted" do
      buyer = create(:user, :attendee, email: "free-used@example.com")
      order = create_free_pass_order(buyer: buyer)
      parent = order.tickets.find_by!(parent_ticket_id: nil)
      child1 = order.tickets.find_by!(event: night_1)
      child2 = order.tickets.find_by!(event: night_2)

      child1.check_in!
      child1.reverse_check_in!

      post "/api/v1/orders/#{order.id}/tickets/#{parent.id}/cancel",
        headers: auth_headers(buyer)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to match(/already been used/i)
      expect(parent.reload).to be_issued
      expect(child2.reload).to be_issued
      expect(free_pass_tt.reload.quantity_sold).to eq(1)
      expect(order.reload).to be_completed
    end
  end

  describe "3. Storm Delays / Reschedules & Single-Night Cancellation" do
    before do
      link_nights(pass_tt, [night_1, night_2])
      night_1_tt
    end

    it "sends informational pass_event_change emails with deterministic idempotency keys, deduping, and NO refund/accept CTAs" do
      pass_order, = create_paid_pass_order(email: "pass-only@example.com", name: "Pass Only")
      both_order, = create_paid_pass_order(email: "Both@Example.com", name: "Both Holder")

      # Direct Night 1 buyer sharing email with both_order
      direct_order = Commerce::OrderCreator.call(
        event: night_1,
        line_items: [{ ticket_type_id: night_1_tt.id, quantity: 1 }],
        buyer_email: "both@example.com",
        buyer_name: "Direct Buyer",
        payment_required: false
      ).order

      # Reschedule Night 1 via organizer update (moving later than pass_event.ends_at!)
      original_pass_end = pass_event.ends_at
      new_start = 15.days.from_now.change(usec: 0)
      new_end = new_start + 3.hours
      patch "/api/v1/organizer/events/#{night_1.id}",
        params: {
          starts_at: new_start.iso8601,
          ends_at: new_end.iso8601,
          change_reason: "Typhoon Mawar delay"
        },
        headers: owner_headers
      expect(response).to have_http_status(:ok)

      # Configured pass_event.ends_at stays preserved while effective_ends_at tracks rescheduled Night 1
      expect(pass_event.reload.ends_at).to be_within(1.second).of(original_pass_end)
      expect(pass_event.effective_ends_at).to be_within(1.second).of(new_end)

      change = night_1.event_changes.last
      expect(change.change_type).to eq("rescheduled")

      # Direct buyer gets event_change, pass-only buyer gets pass_event_change, shared email is deduped!
      direct_deliveries = MessageDelivery.where(template: "event_change", event: night_1, recipient: "both@example.com")
      expect(direct_deliveries.count).to eq(1)
      expect(direct_deliveries.sole.order_id).to eq(direct_order.id)

      pass_deliveries = MessageDelivery.where(template: "pass_event_change", event: night_1)
      expect(pass_deliveries.count).to eq(1)
      delivery = pass_deliveries.sole
      expect(delivery.recipient).to eq("pass-only@example.com")
      expect(MessageDelivery.where(template: "pass_event_change", event: night_1, recipient: "both@example.com")).to be_empty
      expected_key = "event-change/#{change.id}/pass-buyer/#{Digest::SHA256.hexdigest('pass-only@example.com')[0, 32]}"
      expect(delivery.idempotency_key).to eq(expected_key)
      expect(delivery.metadata["audience"]).to eq("pass_buyer")

      # Prepare email payload: informational only, NO Accept / Request Refund CTAs
      payload = EmailService.prepare_delivery_payload(delivery)
      html = payload.fetch("html")
      expect(html).to include("FD Tourney Pass", "Typhoon Mawar delay", "View your pass")
      expect(html).not_to match(/request a refund|keep your tickets|accept/i)

      # Cross-event EventChangeRefundEligibility returns ineligible for pass orders
      eligibility = EventChangeRefundEligibility.call(order: pass_order, change: change)
      expect(eligibility).not_to be_eligible
      expect(eligibility.reason).to eq("wrong_event")
      expect(eligibility.tickets).to eq([])
      expect(both_order).to be_present
      expect(direct_order).to be_present

      # MessageDeliveryJob runs pass_event_change cleanly (does not falsely treat cross-event order as obsolete)
      MessageDeliveryJob.perform_now(delivery.id)
      expect(delivery.reload).to be_sent
    end

    it "derives effective_ends_at when adding a later night via TicketTypesController without overwriting configured ends_at" do
      original_pass_end = pass_event.ends_at
      late_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Playoffs Final", max_capacity: 20, starts_at: 20.days.from_now, ends_at: 20.days.from_now + 4.hours)

      patch "/api/v1/organizer/events/#{pass_event.id}/ticket_types/#{pass_tt.id}",
        params: { included_event_ids: [night_1.id, night_2.id, late_night.id] },
        headers: owner_headers,
        as: :json
      expect(response).to have_http_status(:ok)
      expect(pass_event.reload.ends_at).to be_within(1.second).of(original_pass_end)
      expect(pass_event.effective_ends_at).to be_within(1.second).of(late_night.ends_at)
    end

    it "cancels only active Night 1 child tickets on single-night cancel while preserving parent pass, Night 2, direct refunds, and pass notice" do
      pass_order, = create_paid_pass_order(email: "active-pass@example.com")
      refunded_pass_order, = create_paid_pass_order(email: "refunded-pass@example.com")
      Commerce::RefundCreator.call(order: refunded_pass_order, reason: "requested_by_customer", requested_by: owner)

      # Direct Night 1 paid order
      direct_checkout = Commerce::OrderCreator.call(
        event: night_1,
        line_items: [{ ticket_type_id: night_1_tt.id, quantity: 1 }],
        buyer_email: "direct-night1@example.com",
        buyer_name: "Direct Fan",
        payment_required: true
      )
      Commerce::OrderLifecycle.complete!(
        direct_checkout.order,
        payment: direct_checkout.payment,
        provider_amount_cents: direct_checkout.payment.amount_cents,
        provider_currency: direct_checkout.payment.currency
      )

      parent = pass_order.tickets.find_by!(parent_ticket_id: nil)
      night_1_child = pass_order.tickets.find_by!(event: night_1)
      night_2_child = pass_order.tickets.find_by!(event: night_2)
      night_1_version_before = night_1_child.scan_credential_version

      EventLifecycle.call(event: night_1, action: :cancel, actor: owner, reason: "Gym roof leak")

      # Direct Night 1 order is in EventCancellationRefundRun; pass order is NOT
      run = night_1.reload.event_cancellation_refund_run
      expect(run.items.pluck(:order_id)).to eq([direct_checkout.order.id])

      # Active Night 1 child cancelled with reason + bumped scan version; parent & Night 2 untouched
      expect(night_1_child.reload).to be_cancelled
      expect(night_1_child.cancellation_reason).to eq("event_cancelled")
      expect(night_1_child.scan_credential_version).to eq(night_1_version_before + 1)
      expect(parent.reload).to be_issued
      expect(night_2_child.reload).to be_issued
      expect(pass_order.reload).to be_completed

      # Only the active pass buyer receives pass_event_change (not the already-refunded pass buyer!)
      pass_deliveries = MessageDelivery.where(template: "pass_event_change", event: night_1)
      expect(pass_deliveries.pluck(:recipient)).to eq(["active-pass@example.com"])
      payload = EmailService.prepare_delivery_payload(pass_deliveries.sole)
      expect(payload.fetch("subject")).to include("Night 1")
      expect(payload.fetch("html")).to include("remaining pass nights stay active", "Gym roof leak", "View your pass")
      expect(payload.fetch("html")).not_to match(/automatic refund|request a refund/i)
    end

    it "still notifies the holder of an admitted (checked_in) pass child when that included night is cancelled" do
      admitted_order, = create_paid_pass_order(email: "admitted-buyer@example.com", name: "Admitted Pass Buyer")
      admitted_child = admitted_order.tickets.find_by!(event: night_1)
      admitted_child.update!(
        holder_email: "admitted-holder@example.com",
        attendee_email: "admitted-holder@example.com"
      )
      admitted_child.check_in!
      expect(admitted_child.reload).to be_checked_in

      EventLifecycle.call(event: night_1, action: :cancel, actor: owner, reason: "Mid-game power outage")

      # Admitted ticket stays checked_in (not cancelled) while both buyer and distinct holder receive cancellation notices
      expect(admitted_child.reload).to be_checked_in
      deliveries = MessageDelivery.where(template: "pass_event_change", event: night_1).index_by(&:recipient)
      expect(deliveries.keys).to contain_exactly("admitted-buyer@example.com", "admitted-holder@example.com")

      buyer_delivery = deliveries.fetch("admitted-buyer@example.com")
      holder_delivery = deliveries.fetch("admitted-holder@example.com")
      expect(buyer_delivery.metadata["audience"]).to eq("pass_buyer")
      expect(holder_delivery.metadata["audience"]).to eq("pass_holder")

      buyer_html = EmailService.prepare_delivery_payload(buyer_delivery).fetch("html")
      expect(buyer_html).to include("/orders/#{admitted_order.id}/confirmation#guest_token=")
      issued_token = buyer_html[/#guest_token=([^"&]+)/, 1]
      expect(issued_token).to be_present

      holder_html = EmailService.prepare_delivery_payload(holder_delivery).fetch("html")
      expect(holder_html).to include("Mid-game power outage", "/my-tickets")
      expect(holder_html).not_to include("/orders/#{admitted_order.id}", "guest_token", issued_token)
    end

    it "skips cancelled included nights in both Passes::SyncPassHolders and Passes::Issuance" do
      existing_order, = create_paid_pass_order(email: "existing-sync@example.com")

      cancelled_night = create(:event, :cancelled, organizer_profile: profile, organization: org,
        title: "Cancelled Night", max_capacity: 20, starts_at: 5.days.from_now, ends_at: 5.days.from_now + 3.hours)
      active_new_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Active Added Night", max_capacity: 20, starts_at: 6.days.from_now, ends_at: 6.days.from_now + 3.hours)

      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: cancelled_night, position: 2)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: active_new_night, position: 3)

      sync_result = Passes::SyncPassHolders.call(ticket_type: pass_tt, actor: owner)
      expect(sync_result.issued_ticket_count).to eq(1)
      expect(sync_result.included_event_ids).to contain_exactly(night_1.id, night_2.id, active_new_night.id)
      expect(existing_order.tickets.where(event: active_new_night).count).to eq(1)
      expect(existing_order.tickets.where(event: cancelled_night).count).to eq(0)

      # New pass purchase also skips the cancelled night
      new_order, = create_paid_pass_order(email: "new-purchase@example.com")
      child_event_ids = new_order.tickets.where.not(parent_ticket_id: nil).pluck(:event_id)
      expect(child_event_ids).to contain_exactly(night_1.id, night_2.id, active_new_night.id)
      expect(child_event_ids).not_to include(cancelled_night.id)
    end

    it "separates buyer and attendee pass_event_change emails without leaking guest order tokens to attendees" do
      with_locales_enabled(%w[en ko])
      guest_order, = create_paid_pass_order(buyer: nil, email: "guest-buyer@example.com", name: "Guest Buyer")
      guest_order.update!(locale: "ko")
      guest_order.tickets.update_all(
        attendee_email: "guest-attendee@example.com",
        holder_email: "guest-attendee@example.com"
      )

      new_start = 16.days.from_now.change(usec: 0)
      patch "/api/v1/organizer/events/#{night_1.id}",
        params: { starts_at: new_start.iso8601, ends_at: (new_start + 3.hours).iso8601, change_reason: "Rain delay" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)

      change = night_1.event_changes.last
      deliveries = MessageDelivery.where(template: "pass_event_change", event: night_1).index_by(&:recipient)
      expect(deliveries.keys).to contain_exactly("guest-buyer@example.com", "guest-attendee@example.com")

      buyer_delivery = deliveries.fetch("guest-buyer@example.com")
      attendee_delivery = deliveries.fetch("guest-attendee@example.com")
      expect(buyer_delivery.metadata["audience"]).to eq("pass_buyer")
      expect(buyer_delivery.idempotency_key).to eq(
        "event-change/#{change.id}/pass-buyer/#{Digest::SHA256.hexdigest('guest-buyer@example.com')[0, 32]}"
      )
      expect(attendee_delivery.metadata["audience"]).to eq("pass_holder")
      expect(attendee_delivery.idempotency_key).to eq(
        "event-change/#{change.id}/pass-holder/#{Digest::SHA256.hexdigest('guest-attendee@example.com')[0, 32]}"
      )

      buyer_html = EmailService.prepare_delivery_payload(buyer_delivery).fetch("html")
      expect(buyer_html).to include('<html lang="ko">', "제공: HåfaPass · Shimizu Technology")
      expect(buyer_html).to include("/orders/#{guest_order.id}/confirmation#guest_token=")
      issued_token = buyer_html[/#guest_token=([^"&]+)/, 1]
      expect(issued_token).to be_present

      attendee_html = EmailService.prepare_delivery_payload(attendee_delivery).fetch("html")
      expect(attendee_html).to include('<html lang="en">', "View your tickets", "/my-tickets")
      expect(attendee_html).not_to include("/orders/#{guest_order.id}")
      expect(attendee_html).not_to include("guest_token")
      expect(attendee_html).not_to include(issued_token)

      # Single-night cancel also keeps guest order token strictly on the buyer email
      EventLifecycle.call(event: night_2, action: :cancel, actor: owner, reason: "Power outage")
      cancel_deliveries = MessageDelivery.where(template: "pass_event_change", event: night_2).index_by(&:recipient)
      expect(cancel_deliveries.keys).to contain_exactly("guest-buyer@example.com", "guest-attendee@example.com")

      cancel_buyer_html = EmailService.prepare_delivery_payload(cancel_deliveries.fetch("guest-buyer@example.com")).fetch("html")
      cancel_token = cancel_buyer_html[/#guest_token=([^"&]+)/, 1]
      expect(cancel_token).to be_present

      cancel_attendee_html = EmailService.prepare_delivery_payload(cancel_deliveries.fetch("guest-attendee@example.com")).fetch("html")
      expect(cancel_attendee_html).to include('<html lang="en">', "/my-tickets")
      expect(cancel_attendee_html).not_to include("/orders/#{guest_order.id}", "guest_token", cancel_token)
    end

    it "excludes lost-dispute retained passes and open-dispute passes from SyncPassHolders and pass_event_change emails" do
      lost_order, lost_payment = create_paid_pass_order(email: "lost-dispute@example.com", name: "Lost Dispute Fan")
      open_order, open_payment = create_paid_pass_order(email: "open-dispute@example.com", name: "Open Dispute Fan")
      healthy_order, = create_paid_pass_order(email: "healthy-pass@example.com", name: "Healthy Fan")

      # Lost dispute on a partly used pass: parent remains issued + inventory_retained, order stays completed + blocked
      lost_parent = lost_order.tickets.find_by!(parent_ticket_id: nil)
      lost_child_1 = lost_order.tickets.find_by!(event: night_1)
      lost_child_1.check_in!
      lost_dispute_event = OpenStruct.new(
        id: "evt_lost_pass_exclude",
        type: "charge.dispute.closed",
        created: Time.current.to_i,
        data: OpenStruct.new(
          object: {
            "id" => "dp_lost_pass_exclude",
            "payment_intent" => lost_payment.provider_payment_id,
            "amount" => lost_order.total_cents,
            "currency" => lost_order.currency,
            "reason" => "fraudulent",
            "status" => "lost"
          }
        )
      )
      StripeWebhookProcessor.call(event: lost_dispute_event, payload: { "id" => lost_dispute_event.id, "type" => lost_dispute_event.type })
      expect(lost_order.reload).to be_completed
      expect(lost_order).to be_ticket_access_blocked
      expect(lost_parent.reload).to be_issued
      expect(lost_parent).to be_inventory_retained

      # Open dispute on another pass order: child tickets stay issued, order is ticket_access_blocked
      Dispute.create!(
        order: open_order,
        payment: open_payment,
        provider_dispute_id: "dp_open_pass_exclude",
        status: :open,
        reason: "general",
        amount_cents: open_order.total_cents,
        currency: open_order.currency,
        opened_at: Time.current
      )
      expect(open_order.reload).to be_ticket_access_blocked

      # Add a new night and run SyncPassHolders: 0 children issued for lost/open dispute orders, 1 for healthy order
      night_4 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night 4 Finals", max_capacity: 20, starts_at: 5.days.from_now, ends_at: 5.days.from_now + 3.hours)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_4, position: 2)

      sync_result = Passes::SyncPassHolders.call(ticket_type: pass_tt, actor: owner)
      expect(sync_result.parent_ticket_count).to eq(1)
      expect(sync_result.issued_ticket_count).to eq(1)
      expect(lost_order.tickets.where(event: night_4).count).to eq(0)
      expect(open_order.tickets.where(event: night_4).count).to eq(0)
      expect(healthy_order.tickets.where(event: night_4).count).to eq(1)

      # Even if an admitted/undone child on the lost-dispute pass is in issued status, rescheduling sends 0 emails
      lost_child_1.reverse_check_in!
      expect(lost_child_1.reload).to be_issued

      new_start = 17.days.from_now.change(usec: 0)
      patch "/api/v1/organizer/events/#{night_1.id}",
        params: { starts_at: new_start.iso8601, ends_at: (new_start + 3.hours).iso8601, change_reason: "Weather shift" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)

      recipients = MessageDelivery.where(template: "pass_event_change", event: night_1).pluck(:recipient)
      expect(recipients).to eq(["healthy-pass@example.com"])
    end

    it "never mutates pass_event.ends_at on night reschedule, ignores cancelled nights, and is unaffected by unrelated pass validations" do
      original_pass_end = pass_event.ends_at
      completed_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Completed Pass", max_capacity: 50, starts_at: 2.days.from_now, ends_at: 5.days.from_now)
      completed_pass_tt = create(:ticket_type, event: completed_pass, name: "Completed Pass TT", price_cents: 2000, quantity_available: 10)
      link_nights(completed_pass_tt, [night_1])
      completed_pass.update_columns(status: Event.statuses.fetch("completed"))

      # Unrelated validation error on active pass_event must NOT block rescheduling Night 1
      pass_event.update_columns(title: "")
      expect(pass_event.reload).not_to be_valid

      # Cancelled included night with a far-future end date must be ignored
      cancelled_night = create(:event, :cancelled, organizer_profile: profile, organization: org,
        title: "Cancelled Far Night", max_capacity: 20, starts_at: 40.days.from_now, ends_at: 40.days.from_now + 3.hours)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: cancelled_night, position: 2)

      new_start = 18.days.from_now.change(usec: 0)
      new_end = new_start + 3.hours
      patch "/api/v1/organizer/events/#{night_1.id}",
        params: { starts_at: new_start.iso8601, ends_at: new_end.iso8601, change_reason: "Storm move" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)

      expect(pass_event.reload.ends_at).to be_within(1.second).of(original_pass_end)
      expect(pass_event.effective_ends_at).to be_within(1.second).of(new_end)
      expect(completed_pass.reload.ends_at).to be_within(1.second).of(5.days.from_now)
    end

    it "tracks pass_event.effective_ends_at downward when a storm-extended night is moved earlier while preserving configured ends_at" do
      original_pass_end = pass_event.ends_at
      far_start = 18.days.from_now.change(usec: 0)
      far_end = far_start + 3.hours
      patch "/api/v1/organizer/events/#{night_2.id}",
        params: { starts_at: far_start.iso8601, ends_at: far_end.iso8601, change_reason: "Typhoon delay" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)
      expect(pass_event.reload.ends_at).to be_within(1.second).of(original_pass_end)
      expect(pass_event.effective_ends_at).to be_within(1.second).of(far_end)

      earlier_start = 6.days.from_now.change(usec: 0)
      earlier_end = earlier_start + 3.hours
      patch "/api/v1/organizer/events/#{night_2.id}",
        params: { starts_at: earlier_start.iso8601, ends_at: earlier_end.iso8601, change_reason: "Moved back earlier" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)
      expect(pass_event.reload.ends_at).to be_within(1.second).of(original_pass_end)
      expect(pass_event.effective_ends_at).to be_within(1.second).of(earlier_end)
    end

    it "skips an unattempted pass_event_change delivery if the pass order was fully refunded before send while preserving replays" do
      refunded_order, = create_paid_pass_order(email: "refunded-in-window@example.com", name: "Refunded Fan")
      replayed_order, = create_paid_pass_order(email: "replayed-fan@example.com", name: "Replayed Fan")

      new_start = 15.days.from_now.change(usec: 0)
      patch "/api/v1/organizer/events/#{night_1.id}",
        params: { starts_at: new_start.iso8601, ends_at: (new_start + 3.hours).iso8601, change_reason: "Schedule shift" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)

      unattempted = MessageDelivery.find_by!(template: "pass_event_change", event: night_1, recipient: "refunded-in-window@example.com")
      replayed = MessageDelivery.find_by!(template: "pass_event_change", event: night_1, recipient: "replayed-fan@example.com")
      # Simulate an already-attempted delivery whose payload was captured before the refund
      frozen_payload = EmailService.prepare_delivery_payload(replayed)
      replayed.update!(outbound_payload: frozen_payload, attempts: 1, provider: "simulated")

      Commerce::RefundCreator.call(order: refunded_order, reason: "requested_by_customer", requested_by: owner, idempotency_key: "refund-before-send-1")
      Commerce::RefundCreator.call(order: replayed_order, reason: "requested_by_customer", requested_by: owner, idempotency_key: "refund-before-replay-2")

      MessageDeliveryJob.perform_now(unattempted.id)
      expect(unattempted.reload).to be_cancelled
      expect(unattempted.attempts).to eq(0)
      expect(unattempted.outbound_payload).to be_blank
      expect(unattempted.sent_at).to be_nil

      # Already-attempted replay is not cancelled by the unattempted eligibility check
      MessageDeliveryJob.perform_now(replayed.id)
      expect(replayed.reload).to be_sent
    end

    it "preserves a deduplicated pass_event_change notice by switching to another eligible order for the same recipient and audience" do
      with_locales_enabled(%w[en ko])
      order_a, = create_paid_pass_order(buyer: nil, email: "multi-pass-buyer@example.com", name: "Multi Pass Buyer")
      order_b, = create_paid_pass_order(buyer: nil, email: "multi-pass-buyer@example.com", name: "Multi Pass Buyer")
      order_b.update!(locale: "ko")

      # Separate non-buyer holder across two orders purchased by another buyer
      other_order_a, = create_paid_pass_order(buyer: nil, email: "other-buyer@example.com", name: "Other Buyer")
      other_order_b, = create_paid_pass_order(buyer: nil, email: "other-buyer@example.com", name: "Other Buyer")
      [other_order_a, other_order_b].each do |ord|
        ord.tickets.update_all(
          attendee_email: "shared-holder@example.com",
          holder_email: "shared-holder@example.com"
        )
      end

      # Buyer who also happens to be a non-buyer holder on a different buyer's order (must never cross audiences)
      cross_buyer_order, = create_paid_pass_order(buyer: nil, email: "cross-audience@example.com", name: "Cross Buyer")
      third_party_order, = create_paid_pass_order(buyer: nil, email: "third-party@example.com", name: "Third Party")
      third_party_order.tickets.update_all(
        attendee_email: "cross-audience@example.com",
        holder_email: "cross-audience@example.com"
      )

      new_start = 15.days.from_now.change(usec: 0)
      patch "/api/v1/organizer/events/#{night_1.id}",
        params: { starts_at: new_start.iso8601, ends_at: (new_start + 3.hours).iso8601, change_reason: "Weather delay" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)

      buyer_deliveries = MessageDelivery.where(template: "pass_event_change", event: night_1, recipient: "multi-pass-buyer@example.com")
      expect(buyer_deliveries.count).to eq(1)
      buyer_delivery = buyer_deliveries.sole
      expect(buyer_delivery.order_id).to eq(order_a.id)

      holder_deliveries = MessageDelivery.where(template: "pass_event_change", event: night_1, recipient: "shared-holder@example.com")
      expect(holder_deliveries.count).to eq(1)
      holder_delivery = holder_deliveries.sole
      expect(holder_delivery.order_id).to eq(other_order_a.id)
      expect(holder_delivery.metadata["audience"]).to eq("pass_holder")

      cross_delivery = MessageDelivery.find_by!(template: "pass_event_change", event: night_1, recipient: "cross-audience@example.com")
      expect(cross_delivery.order_id).to eq(cross_buyer_order.id)
      expect(cross_delivery.metadata["audience"]).to eq("pass_buyer")

      # Refund order A before MessageDeliveryJob runs -> delivery switches to order B and sends with order B's access link & locale
      Commerce::RefundCreator.call(order: order_a, reason: "requested_by_customer", requested_by: owner, idempotency_key: "refund-multi-a")
      MessageDeliveryJob.perform_now(buyer_delivery.id)
      buyer_delivery.reload
      expect(buyer_delivery).to be_sent
      expect(buyer_delivery.order_id).to eq(order_b.id)
      buyer_html = buyer_delivery.outbound_payload.fetch("html")
      expect(buyer_html).to include('<html lang="ko">', "/orders/#{order_b.id}/confirmation#guest_token=")
      expect(buyer_html).not_to include("/orders/#{order_a.id}")

      # Refund other_order_a -> holder delivery switches to other_order_b, stays pass_holder with /my-tickets and NO guest token
      Commerce::RefundCreator.call(order: other_order_a, reason: "requested_by_customer", requested_by: owner, idempotency_key: "refund-holder-a")
      MessageDeliveryJob.perform_now(holder_delivery.id)
      holder_delivery.reload
      expect(holder_delivery).to be_sent
      expect(holder_delivery.order_id).to eq(other_order_b.id)
      expect(holder_delivery.ticket_id).to eq(other_order_b.tickets.find_by!(event: night_1).id)
      holder_html = holder_delivery.outbound_payload.fetch("html")
      expect(holder_html).to include('<html lang="en">', "/my-tickets")
      expect(holder_html).not_to include("guest_token", "/orders/#{other_order_b.id}", "/orders/#{other_order_a.id}")

      # Refund cross_buyer_order -> pass_buyer delivery must NOT switch to third_party_order (different buyer_email)
      Commerce::RefundCreator.call(order: cross_buyer_order, reason: "requested_by_customer", requested_by: owner, idempotency_key: "refund-cross-buyer")
      MessageDeliveryJob.perform_now(cross_delivery.id)
      expect(cross_delivery.reload).to be_cancelled
      expect(cross_delivery.outbound_payload).to be_blank
    end

    it "rejects new pass checkouts with 422 when all included nights are cancelled while allowing checkouts with surviving nights" do
      EventLifecycle.call(event: night_1, action: :cancel, actor: owner, reason: "Night 1 rained out")

      # Night 2 still survives -> checkout succeeds and issues 1 child for Night 2
      partial_order, = create_paid_pass_order(email: "surviving-night@example.com")
      expect(partial_order.tickets.where.not(parent_ticket_id: nil).pluck(:event_id)).to eq([night_2.id])

      # Cancel the final surviving night -> new pass checkout rejected (422)
      EventLifecycle.call(event: night_2, action: :cancel, actor: owner, reason: "Night 2 rained out")

      expect do
        Commerce::OrderCreator.call(
          event: pass_event,
          line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
          buyer_email: "all-cancelled@example.com",
          buyer_name: "Late Buyer",
          payment_required: true
        )
      end.to raise_error(Commerce::OrderCreator::CheckoutError, "All included nights for this pass have been cancelled")

      post "/api/v1/orders",
        params: {
          event_id: pass_event.id,
          buyer_email: "http-all-cancelled@example.com",
          buyer_name: "HTTP Buyer",
          terms_accepted: true,
          terms_version: PolicyRegistry.buyer_terms[:version],
          line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }]
        },
        as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("All included nights for this pass have been cancelled")
    end

    it "routes an in-flight paid pass order to refund recovery instead of completing with 0 children when all nights are cancelled" do
      checkout = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "inflight-pass@example.com",
        buyer_name: "Inflight Fan",
        payment_required: true
      )
      order = checkout.order
      payment = checkout.payment
      Payment.where(id: payment.id).update_all(provider_environment: "test", provider_payment_id: "pi_inflight_all_cancelled")
      payment.reload

      EventLifecycle.call(event: night_1, action: :cancel, actor: owner, reason: "Storm night 1")
      EventLifecycle.call(event: night_2, action: :cancel, actor: owner, reason: "Storm night 2")

      result = nil
      expect do
        result = Commerce::OrderLifecycle.complete!(
          order,
          payment: payment,
          provider_amount_cents: payment.amount_cents,
          provider_currency: payment.currency
        )
      end.to have_enqueued_job(LateCaptureRefundJob).with(payment.id)

      expect(result).to eq(:unchanged)
      expect(order.reload).to be_cancelled
      expect(order.completed_at).to be_nil
      expect(order.tickets.count).to eq(0)
      expect(order.inventory_holds.sole).to be_released
      expect(pass_tt.reload.quantity_sold).to eq(0)
      expect(payment.reload).to be_succeeded
      expect(EmailService).not_to have_received(:send_order_confirmation_async)

      issue = ReconciliationException.find_by!(order: order, payment: payment, code: "pass_all_included_nights_cancelled")
      expect(issue).to be_open

      # Running the enqueued LateCaptureRefundJob refunds the captured payment and resolves the exception
      LateCaptureRefundJob.perform_now(payment.id)
      expect(order.reload).to be_refunded
      expect(payment.reload).to be_refunded
      expect(issue.reload).to be_resolved

      # A pending free pass order whose nights are all cancelled also cancels cleanly without completing
      free_pass_tt_local = create(:ticket_type, event: pass_event, name: "Free Storm Pass", price_cents: 0, quantity_available: 10)
      surviving_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Temporary Night", max_capacity: 20, starts_at: 5.days.from_now, ends_at: 5.days.from_now + 3.hours)
      link_nights(free_pass_tt_local, [surviving_night])
      free_order = create(:order, :pending, event: pass_event, total_cents: 0, subtotal_cents: 0, service_fee_cents: 0,
        buyer_email: "free-inflight@example.com", buyer_name: "Free Inflight", expires_at: 10.minutes.from_now)
      free_item = create(:order_item, order: free_order, ticket_type: free_pass_tt_local, quantity: 1, unit_price_cents: 0, subtotal_cents: 0)
      create(:inventory_hold, order: free_order, order_item: free_item, event: pass_event, ticket_type: free_pass_tt_local,
        quantity: 1, expires_at: 10.minutes.from_now)
      EventLifecycle.call(event: surviving_night, action: :cancel, actor: owner, reason: "Cancelled before completion")

      expect(Commerce::OrderLifecycle.complete!(free_order)).to eq(:unchanged)
      expect(free_order.reload).to be_cancelled
      expect(free_order.tickets.count).to eq(0)
      expect(ReconciliationException.where(order: free_order)).to be_empty
    end

    it "keeps cancelled-then-archived included nights ineligible for completion, checkout, discovery, and issuance while allowing surviving published nights" do
      # (a) Cancel then archive the final included night before payment completes -> late-capture refund recovery
      checkout = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "archived-inflight@example.com",
        buyer_name: "Archived Inflight",
        payment_required: true
      )
      order = checkout.order
      payment = checkout.payment
      Payment.where(id: payment.id).update_all(provider_environment: "test", provider_payment_id: "pi_archived_final_night")
      payment.reload

      EventLifecycle.call(event: night_1, action: :cancel, actor: owner, reason: "Storm night 1")
      EventLifecycle.call(event: night_2, action: :cancel, actor: owner, reason: "Storm night 2")
      Settlements::Finalizer.call(event: night_2, actor: owner)
      EventLifecycle.call(event: night_2, action: :archive, actor: owner)
      expect(night_2.reload).to be_archived

      result = nil
      expect do
        result = Commerce::OrderLifecycle.complete!(
          order,
          payment: payment,
          provider_amount_cents: payment.amount_cents,
          provider_currency: payment.currency
        )
      end.to have_enqueued_job(LateCaptureRefundJob).with(payment.id)

      expect(result).to eq(:unchanged)
      expect(order.reload).to be_cancelled
      expect(order.tickets.count).to eq(0)
      expect(ReconciliationException.find_by!(order: order, payment: payment, code: "pass_all_included_nights_cancelled")).to be_open

      # (c) Cancelling then archiving the only future night keeps pass sales and discovery closed
      expect(pass_event.reload.all_pass_nights_cancelled?).to be(true)
      expect(pass_event.sales_open?).to be(false)
      expect(pass_event.sales_blocker).to eq(:pass_nights_cancelled)
      expect(Event.discoverable_base.where(id: pass_event.id)).not_to exist
      expect do
        Commerce::OrderCreator.call(
          event: pass_event,
          line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
          buyer_email: "after-archive@example.com",
          buyer_name: "After Archive",
          payment_required: true
        )
      end.to raise_error(Commerce::OrderCreator::CheckoutError, "All included nights for this pass have been cancelled")

      # (b) One night cancelled+archived while another published night survives -> fulfills for surviving night only
      surviving_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Surviving Pass", max_capacity: 50, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
      archived_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Cancelled Archived Night", max_capacity: 20, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
      live_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Surviving Published Night", max_capacity: 20, starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
      surviving_tt = create(:ticket_type, event: surviving_pass, name: "Surviving Pass TT", price_cents: 2500, quantity_available: 10)
      link_nights(surviving_tt, [archived_night, live_night])

      pending_checkout = Commerce::OrderCreator.call(
        event: surviving_pass,
        line_items: [{ ticket_type_id: surviving_tt.id, quantity: 1 }],
        buyer_email: "surviving-after-archive@example.com",
        buyer_name: "Surviving Buyer",
        payment_required: true
      )
      EventLifecycle.call(event: archived_night, action: :cancel, actor: owner, reason: "Cancelled night")
      Settlements::Finalizer.call(event: archived_night, actor: owner)
      EventLifecycle.call(event: archived_night, action: :archive, actor: owner)
      expect(archived_night.reload).to be_archived

      completed_status = Commerce::OrderLifecycle.complete!(
        pending_checkout.order,
        payment: pending_checkout.payment,
        provider_amount_cents: pending_checkout.payment.amount_cents,
        provider_currency: pending_checkout.payment.currency
      )
      expect(completed_status).to eq(:completed)
      expect(pending_checkout.order.reload).to be_completed
      expect(pending_checkout.order.tickets.where.not(parent_ticket_id: nil).pluck(:event_id)).to eq([live_night.id])

      # Completed-then-archived night does NOT falsely trigger all_pass_nights_cancelled?
      done_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Completed Night Pass", max_capacity: 50, starts_at: 5.days.ago, ends_at: 3.days.ago)
      done_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Completed Night", max_capacity: 20, starts_at: 4.days.ago, ends_at: 3.days.ago)
      done_tt = create(:ticket_type, event: done_pass, name: "Completed Pass TT", price_cents: 0, quantity_available: 10)
      link_nights(done_tt, [done_night])
      EventLifecycle.call(event: done_night, action: :complete, actor: owner, at: Time.current)
      Settlements::Finalizer.call(event: done_night, actor: owner)
      EventLifecycle.call(event: done_night, action: :archive, actor: owner)
      expect(done_night.reload).to be_archived
      expect(done_pass.reload.all_pass_nights_cancelled?).to be(false)
      expect(done_pass.sales_blocker).to eq(:sales_closed)

      # Completed-then-archived night before a FUTURE pass starts_at:
      # all_pass_nights_cancelled? stays false, sales_open? closes with non-cancellation reason,
      # and mixed-event regular GA sales remain open.
      future_done_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Future Start Completed Night Pass", max_capacity: 50, starts_at: 3.days.from_now, ends_at: 10.days.from_now)
      future_done_tt = create(:ticket_type, event: future_done_pass, name: "Future Done Pass TT", price_cents: 0, quantity_available: 10)
      link_nights(future_done_tt, [done_night])
      expect(future_done_pass.reload.all_pass_nights_cancelled?).to be(false)
      expect(future_done_pass.no_eligible_pass_nights?).to be(true)
      expect(future_done_pass.sales_open?).to be(false)
      expect(future_done_pass.sales_blocker).to eq(:sales_closed)
      expect(future_done_pass.sales_status[:reason]).to eq("sales_closed")
      expect(Event.discoverable_base.where(id: future_done_pass.id)).not_to exist
      expect do
        Commerce::OrderCreator.call(
          event: future_done_pass,
          line_items: [{ ticket_type_id: future_done_tt.id, quantity: 1 }],
          buyer_email: "future-done-pass@example.com",
          buyer_name: "Future Done Buyer",
          payment_required: false
        )
      end.to raise_error(Commerce::OrderCreator::CheckoutError, "This event is not currently on sale")

      # Mixed event with a completed-then-archived pass night before future starts_at stays open for regular GA
      mixed_done_ev = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Mixed Completed Archived Event", max_capacity: 50, starts_at: 3.days.from_now, ends_at: 10.days.from_now)
      mixed_done_ga = create(:ticket_type, event: mixed_done_ev, name: "Regular GA", price_cents: 0, quantity_available: 20)
      mixed_done_pass = create(:ticket_type, event: mixed_done_ev, name: "Mixed Completed Pass", price_cents: 0, quantity_available: 10)
      link_nights(mixed_done_pass, [done_night])
      expect(mixed_done_ev.reload.all_pass_nights_cancelled?).to be(false)
      expect(mixed_done_ev.no_eligible_pass_nights?).to be(false)
      expect(mixed_done_ev.sales_open?).to be(true)
      expect(mixed_done_ev.sales_blocker).to be_nil
      mixed_done_ga_order = Commerce::OrderCreator.call(
        event: mixed_done_ev,
        line_items: [{ ticket_type_id: mixed_done_ga.id, quantity: 1 }],
        buyer_email: "mixed-done-ga@example.com",
        buyer_name: "Mixed Done GA Buyer",
        payment_required: false
      ).order
      expect(mixed_done_ga_order).to be_completed

      # Batch archive-history lookup for multiple archived nights runs a single event_state_changes query
      archived_night_2 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Cancelled Archived Night 2", max_capacity: 20, starts_at: 3.days.from_now, ends_at: 3.days.from_now + 3.hours)
      EventLifecycle.call(event: archived_night_2, action: :cancel, actor: owner, reason: "Cancelled night 2")
      Settlements::Finalizer.call(event: archived_night_2, actor: owner)
      EventLifecycle.call(event: archived_night_2, action: :archive, actor: owner)
      multi_archived_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Multi Archived Pass", max_capacity: 50, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
      multi_archived_tt = create(:ticket_type, event: multi_archived_pass, name: "Multi Archived TT", price_cents: 0, quantity_available: 10)
      link_nights(multi_archived_tt, [archived_night, archived_night_2])

      preloaded_pass = Event.includes(ticket_types: { ticket_type_included_events: :included_event }).find(multi_archived_pass.id)
      archive_queries = []
      callback = ->(_name, _start, _finish, _id, payload) do
        archive_queries << payload[:sql] if payload[:sql].include?("event_state_changes") && payload[:name] != "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        expect(preloaded_pass.all_pass_nights_cancelled?).to be(true)
      end
      expect(archive_queries.length).to eq(1)

      # Mixed event keeps regular GA sales & discovery open when all included pass nights are cancelled & archived
      mixed_ev = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Mixed Archived Night Event", max_capacity: 50, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
      mixed_ga = create(:ticket_type, event: mixed_ev, name: "Regular GA", price_cents: 0, quantity_available: 20)
      mixed_pass = create(:ticket_type, event: mixed_ev, name: "Mixed Pass", price_cents: 0, quantity_available: 10)
      mixed_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Mixed Night", max_capacity: 20, starts_at: 5.days.from_now, ends_at: 5.days.from_now + 3.hours)
      link_nights(mixed_pass, [mixed_night])
      EventLifecycle.call(event: mixed_night, action: :cancel, actor: owner, reason: "Mixed night cancelled")
      Settlements::Finalizer.call(event: mixed_night, actor: owner)
      EventLifecycle.call(event: mixed_night, action: :archive, actor: owner)
      expect(mixed_night.reload).to be_archived
      expect(mixed_ev.reload.all_pass_nights_cancelled?).to be(false)
      expect(mixed_ev.sales_open?).to be(true)
      expect(Event.discoverable_base.where(id: mixed_ev.id)).to exist
      expect do
        Commerce::OrderCreator.call(
          event: mixed_ev,
          line_items: [{ ticket_type_id: mixed_pass.id, quantity: 1 }],
          buyer_email: "mixed-pass-blocked@example.com",
          buyer_name: "Mixed Pass Blocked",
          payment_required: false
        )
      end.to raise_error(Commerce::OrderCreator::CheckoutError, "All included nights for this pass have been cancelled")
      ga_order = Commerce::OrderCreator.call(
        event: mixed_ev,
        line_items: [{ ticket_type_id: mixed_ga.id, quantity: 1 }],
        buyer_email: "mixed-ga-ok@example.com",
        buyer_name: "Mixed GA Buyer",
        payment_required: false
      ).order
      expect(ga_order).to be_completed
    end
  end

  describe "4. Pass Event Lifecycle, Retention & Attachments" do
    it "blocks EventLifecycle :complete and CompletePastEventsJob while any included night is published or postponed, ignoring drafts/completed/cancelled" do
      past_start = 10.days.ago
      past_end = 1.day.ago
      past_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Past Pass", max_capacity: 50, starts_at: past_start, ends_at: past_end)
      pub_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Still Published Night", max_capacity: 20, starts_at: 2.days.ago, ends_at: 2.hours.from_now)
      draft_night = create(:event, :draft, organizer_profile: profile, organization: org,
        title: "Draft Night", max_capacity: 20, starts_at: 2.days.ago, ends_at: 1.day.ago)
      cancelled_night = create(:event, :cancelled, organizer_profile: profile, organization: org,
        title: "Cancelled Night", max_capacity: 20, starts_at: 3.days.ago, ends_at: 2.days.ago)
      pt = create(:ticket_type, event: past_pass, name: "Past Pass TT", price_cents: 2000, quantity_available: 10)
      link_nights(pt, [pub_night, draft_night, cancelled_night])
      # Simulate past_pass.ends_at having elapsed while pub_night is still active
      past_pass.update_columns(ends_at: 1.day.ago)

      expect do
        EventLifecycle.call(event: past_pass, action: :complete, actor: owner, at: Time.current)
      end.to raise_error(EventLifecycle::TransitionError, /included nights are still published or postponed/i)

      # CompletePastEventsJob skips cleanly without Sentry error
      allow(Sentry).to receive(:capture_exception)
      expect(CompletePastEventsJob.perform_now(now: Time.current)).to eq(0)
      expect(Sentry).not_to have_received(:capture_exception)
      expect(past_pass.reload).to be_published

      # Postponed included night also blocks completion
      pub_night.update_columns(status: Event.statuses.fetch("postponed"))
      expect do
        EventLifecycle.call(event: past_pass, action: :complete, actor: owner, at: Time.current)
      end.to raise_error(EventLifecycle::TransitionError, /included nights are still published or postponed/i)

      # Once pub_night ends and completes, draft & cancelled nights do NOT block pass completion
      pub_night.update_columns(status: Event.statuses.fetch("completed"), ends_at: 1.day.ago)
      expect(CompletePastEventsJob.perform_now(now: Time.current)).to eq(1)
      expect(past_pass.reload).to be_completed
    end

    it "keeps an active Season Pass classified as upcoming on Night 2 and protects it from DataRetentionPurgeJob" do
      buyer = create(:user, :attendee, email: "season-holder@example.com")
      n1 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night 1 Ended", max_capacity: 20, starts_at: 2.days.ago, ends_at: 1.day.ago)
      n15 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night 15 Future", max_capacity: 20, starts_at: 10.days.from_now, ends_at: 10.days.from_now + 3.hours)
      season_pass_event = create(:event, :published, organizer_profile: profile, organization: org,
        title: "15-Night Season Pass", max_capacity: 50, starts_at: 2.days.ago, ends_at: 10.days.from_now + 3.hours)
      season_tt = create(:ticket_type, event: season_pass_event, name: "Season Pass", price_cents: 5000, quantity_available: 50)
      link_nights(season_tt, [n1, n15])

      order = create(:order, event: season_pass_event, user: buyer, buyer_email: buyer.email, buyer_name: "Season Holder")
      item = create(:order_item, order: order, ticket_type: season_tt, quantity: 1)
      parent = create(:ticket, order: order, order_item: item, event: season_pass_event, ticket_type: season_tt, holder_user: buyer)
      Passes::Issuance.call(order: order, parent_ticket: parent)
      n1_child = order.tickets.find_by!(event: n1)
      n15_child = order.tickets.find_by!(event: n15)

      # Even if season_pass_event.ends_at were stale, effective_ends_at anchors to Night 15
      season_pass_event.update_columns(ends_at: 1.day.ago)

      get "/api/v1/me/tickets", params: { tab: "upcoming" }, headers: auth_headers(buyer)
      expect(response).to have_http_status(:ok)
      upcoming_ids = response.parsed_body.fetch("tickets").pluck("id")
      expect(upcoming_ids).to eq([parent.id])
      parent_json = response.parsed_body.fetch("tickets").first
      expect(parent_json["upcoming"]).to be(true)
      expect(parent_json["pass_parent"]).to be(true)
      expect(parent_json.fetch("child_tickets").pluck("id")).to eq([n1_child.id, n15_child.id])
      expect(Time.zone.parse(parent_json.dig("event", "ends_at"))).to be_within(1.second).of(n15.ends_at)

      get "/api/v1/me/tickets", params: { tab: "past" }, headers: auth_headers(buyer)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("tickets")).to be_empty

      # DataRetentionPurgeJob protects active pass order & tickets even if created > 7 years ago
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("DATA_RETENTION_DESTRUCTIVE_ENABLED").and_return("true")
      SiteSetting.instance.update_columns(retention_purge_enabled: true)
      order.update_columns(completed_at: 8.years.ago, created_at: 8.years.ago)
      order.tickets.update_all(created_at: 8.years.ago)

      # Also create a fully ended pass (> 7 years ago) to prove the purge actually ran
      ended_night = create(:event, :completed, organizer_profile: profile, organization: org,
        title: "Old Night", max_capacity: 20, starts_at: 8.years.ago - 2.days, ends_at: 8.years.ago - 1.day)
      ended_pass_event = create(:event, :completed, organizer_profile: profile, organization: org,
        title: "Old Ended Pass", max_capacity: 50, starts_at: 8.years.ago - 2.days, ends_at: 8.years.ago - 1.day)
      ended_tt = create(:ticket_type, event: ended_pass_event, name: "Old Season Pass", price_cents: 5000, quantity_available: 10)
      link_nights(ended_tt, [ended_night])
      ended_order = create(:order, event: ended_pass_event, buyer_email: "old-pass@example.com", buyer_name: "Old Holder")
      ended_item = create(:order_item, order: ended_order, ticket_type: ended_tt, quantity: 1)
      ended_parent = create(:ticket, order: ended_order, order_item: ended_item, event: ended_pass_event, ticket_type: ended_tt)
      Passes::Issuance.call(order: ended_order, parent_ticket: ended_parent)
      ended_child = ended_order.tickets.find_by!(event: ended_night)
      ended_order.update_columns(completed_at: 8.years.ago, created_at: 8.years.ago)
      ended_order.tickets.update_all(created_at: 8.years.ago)

      DataRetentionPurgeJob.perform_now(at: Time.current)
      expect(order.reload.retention_anonymized_at).to be_nil
      expect(parent.reload.retention_anonymized_at).to be_nil
      expect(n1_child.reload.retention_anonymized_at).to be_nil
      expect(n15_child.reload.retention_anonymized_at).to be_nil

      expect(ended_order.reload.retention_anonymized_at).to be_present
      expect(ended_parent.reload.retention_anonymized_at).to be_present
      expect(ended_child.reload.retention_anonymized_at).to be_present
    end

    it "keeps a pass event open for sales via effective_ends_at while ignoring cancelled included nights" do
      buyer = create(:user, :attendee, email: "sales-gate@example.com")
      active_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Active Future Night", max_capacity: 20, starts_at: 5.days.from_now, ends_at: 5.days.from_now + 3.hours)
      cancelled_far_night = create(:event, :cancelled, organizer_profile: profile, organization: org,
        title: "Cancelled Far Future Night", max_capacity: 20, starts_at: 30.days.from_now, ends_at: 30.days.from_now + 3.hours)
      early_pass_event = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Early Ends Pass", max_capacity: 50, starts_at: 3.days.ago, ends_at: 1.day.ago)
      early_pass_tt = create(:ticket_type, event: early_pass_event, name: "Early Pass", price_cents: 0, quantity_available: 10)
      link_nights(early_pass_tt, [active_night, cancelled_far_night])
      early_pass_event.update_columns(ends_at: 1.day.ago)

      # Effective end ignores cancelled_far_night and anchors to active_night; sales & discovery stay open
      expect(early_pass_event.effective_ends_at).to be_within(1.second).of(active_night.ends_at)
      expect(early_pass_event.sales_open?).to be(true)
      expect(early_pass_event.sales_blocker).to be_nil
      expect(Event.discoverable_base.where(id: early_pass_event.id)).to exist

      order = create(:order, event: early_pass_event, user: buyer, buyer_email: buyer.email, buyer_name: "Sales Gate Fan")
      item = create(:order_item, order: order, ticket_type: early_pass_tt, quantity: 1)
      parent = create(:ticket, order: order, order_item: item, event: early_pass_event, ticket_type: early_pass_tt, holder_user: buyer)
      Passes::Issuance.call(order: order, parent_ticket: parent)

      # Once active_night is also cancelled, effective_ends_at falls back to starts_at (not stale ends_at)
      active_night.update_columns(status: Event.statuses.fetch("cancelled"))
      expect(early_pass_event.effective_ends_at).to be_within(1.second).of(early_pass_event.starts_at)
      expect(early_pass_event.sales_open?).to be(false)
      expect(early_pass_event.sales_blocker).to eq(:pass_nights_cancelled)
      expect(early_pass_event.sales_status[:message]).to eq("All included nights for this pass have been cancelled")
      expect(Event.discoverable_base.where(id: early_pass_event.id)).not_to exist

      get "/api/v1/me/tickets", params: { tab: "upcoming" }, headers: auth_headers(buyer)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("tickets").pluck("id")).not_to include(parent.id)

      get "/api/v1/me/tickets", params: { tab: "past" }, headers: auth_headers(buyer)
      expect(response).to have_http_status(:ok)
      past_parent = response.parsed_body.fetch("tickets").find { |t| t["id"] == parent.id }
      expect(past_parent).to be_present
      expect(past_parent["upcoming"]).to be(false)
    end

    it "derives effective_ends_at dynamically on latest night cancellation so sales and discovery close after surviving nights end" do
      configured_end = 5.days.from_now.change(usec: 0)
      synced_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Synced Tourney Pass", max_capacity: 50, starts_at: 2.days.from_now, ends_at: configured_end)
      synced_night_1 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Synced Night 1", max_capacity: 20, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
      synced_night_2 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Synced Night 2", max_capacity: 20, starts_at: 10.days.from_now, ends_at: 10.days.from_now + 3.hours)
      synced_tt = create(:ticket_type, event: synced_pass, name: "Synced Pass TT", price_cents: 0, quantity_available: 10)
      link_nights(synced_tt, [synced_night_1, synced_night_2])

      # Configured ends_at stays preserved while effective_ends_at tracks Night 2's end
      expect(synced_pass.reload.ends_at).to be_within(1.second).of(configured_end)
      expect(synced_pass.effective_ends_at).to be_within(1.second).of(synced_night_2.ends_at)
      expect(Event.discoverable_base.where(id: synced_pass.id)).to exist

      # Cancel Night 2 through EventLifecycle -> effective_ends_at drops back to Night 1's end
      EventLifecycle.call(event: synced_night_2, action: :cancel, actor: owner, reason: "Storm cancelled final night")
      expect(synced_pass.reload.ends_at).to be_within(1.second).of(configured_end)
      expect(synced_pass.effective_ends_at).to be_within(1.second).of(synced_night_1.ends_at)

      # After Night 1 ends (and before Night 2's former end), sales and discovery are closed
      travel_to(3.days.from_now) do
        expect(synced_pass.reload.sales_open?).to be(false)
        expect(Event.discoverable_base.where(id: synced_pass.id)).not_to exist
      end
    end

    it "reverts effective_ends_at, closes sales/discovery, and allows completion when the final surviving included night is cancelled" do
      pass_start = 2.days.from_now.change(usec: 0)
      configured_end = 5.days.from_now.change(usec: 0)
      final_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Final Night Pass", max_capacity: 50, starts_at: pass_start, ends_at: configured_end)
      cancelled_n1 = create(:event, :cancelled, organizer_profile: profile, organization: org,
        title: "Already Cancelled Night 1", max_capacity: 20, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
      surviving_n2 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Surviving Night 2", max_capacity: 20, starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
      final_tt = create(:ticket_type, event: final_pass, name: "Final Pass TT", price_cents: 0, quantity_available: 10)
      link_nights(final_tt, [cancelled_n1, surviving_n2])

      # Reschedule the final surviving night to day 18: configured ends_at stays preserved, effective_ends_at extends to day 18
      day_18_start = 18.days.from_now.change(usec: 0)
      day_18_end = day_18_start + 3.hours
      patch "/api/v1/organizer/events/#{surviving_n2.id}",
        params: { starts_at: day_18_start.iso8601, ends_at: day_18_end.iso8601, change_reason: "Typhoon reschedule to day 18" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)
      expect(final_pass.reload.ends_at).to be_within(1.second).of(configured_end)
      expect(final_pass.effective_ends_at).to be_within(1.second).of(day_18_end)
      expect(final_pass.sales_open?).to be(true)
      expect(Event.discoverable_base.where(id: final_pass.id)).to exist

      # Cancel the final surviving night through EventLifecycle
      EventLifecycle.call(event: surviving_n2, action: :cancel, actor: owner, reason: "Final night cancelled")

      final_pass.reload
      expect(final_pass.ends_at).to be_within(1.second).of(configured_end)
      expect(final_pass).to be_valid
      expect(final_pass.effective_ends_at).to be_within(1.second).of(pass_start)
      expect(final_pass.sales_open?).to be(false)
      expect(final_pass.sales_blocker).to eq(:pass_nights_cancelled)
      expect(final_pass.sales_status[:message]).to eq("All included nights for this pass have been cancelled")
      expect(Event.discoverable_base.where(id: final_pass.id)).not_to exist

      # Completion is NOT blocked or delayed until day 18
      travel_to(3.days.from_now) do
        expect { EventLifecycle.call(event: final_pass, action: :complete, actor: owner, at: Time.current) }.not_to raise_error
        expect(final_pass.reload).to be_completed
      end
    end

    it "preserves configured ends_at on mixed events across night reschedule and cancellation without leaving a stale extension" do
      configured_start = 2.days.from_now.change(usec: 0)
      configured_end = 10.days.from_now.change(usec: 0)
      mixed_event = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Mixed Festival Event", max_capacity: 100, starts_at: configured_start, ends_at: configured_end)
      create(:ticket_type, event: mixed_event, name: "Regular GA", price_cents: 0, quantity_available: 50)
      mixed_pass_tt = create(:ticket_type, event: mixed_event, name: "Multi-Night Pass", price_cents: 0, quantity_available: 20)
      mixed_night_2 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Mixed Night 2", max_capacity: 50, starts_at: 8.days.from_now, ends_at: 8.days.from_now + 3.hours)
      link_nights(mixed_pass_tt, [mixed_night_2])

      expect(mixed_event.pass_only_event?).to be(false)

      # Reschedule Night 2 to Day 18: configured ends_at stays Day 10, effective_ends_at extends to Day 18
      day_18_start = 18.days.from_now.change(usec: 0)
      day_18_end = day_18_start + 3.hours
      patch "/api/v1/organizer/events/#{mixed_night_2.id}",
        params: { starts_at: day_18_start.iso8601, ends_at: day_18_end.iso8601, change_reason: "Rescheduled to day 18" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)

      expect(mixed_event.reload.ends_at).to be_within(1.second).of(configured_end)
      expect(mixed_event.effective_ends_at).to be_within(1.second).of(day_18_end)

      # On Day 12 (after configured Day 10, while Night 2 is active on Day 18): sales & discovery stay open,
      # and CompletePastEventsJob skips completion because Night 2 is still published
      travel_to(12.days.from_now) do
        expect(mixed_event.reload.sales_open?).to be(true)
        expect(Event.discoverable_base.where(id: mixed_event.id)).to exist
        expect(CompletePastEventsJob.perform_now(now: Time.current)).to eq(0)
        expect(mixed_event.reload).to be_published
      end

      # Cancel Night 2 via EventLifecycle
      EventLifecycle.call(event: mixed_night_2, action: :cancel, actor: owner, reason: "Night 2 cancelled")

      # Before configured Day 10 (e.g., Day 8): mixed event stays open/discoverable for its regular GA ticket type
      travel_to(8.days.from_now) do
        expect(mixed_event.reload.ends_at).to be_within(1.second).of(configured_end)
        expect(mixed_event.effective_ends_at).to be_within(1.second).of(configured_end)
        expect(mixed_event.sales_open?).to be(true)
        expect(Event.discoverable_base.where(id: mixed_event.id)).to exist
      end

      # On Day 12 (after configured Day 10, before cancelled Day 18): effective_ends_at reverted to Day 10,
      # sales/discovery close immediately, and CompletePastEventsJob completes it cleanly (not delayed until Day 18)
      travel_to(12.days.from_now) do
        expect(mixed_event.reload.ends_at).to be_within(1.second).of(configured_end)
        expect(mixed_event.effective_ends_at).to be_within(1.second).of(configured_end)
        expect(mixed_event.sales_open?).to be(false)
        expect(mixed_event.sales_blocker).to eq(:sales_closed)
        expect(Event.discoverable_base.where(id: mixed_event.id)).not_to exist
        expect(CompletePastEventsJob.perform_now(now: Time.current)).to eq(1)
        expect(mixed_event.reload).to be_completed
      end
    end

    it "keeps a mixed event discoverable on Day 12 when pass sales ended on Day 10 but regular GA remains on sale through an extended included night" do
      configured_start = 2.days.from_now.change(usec: 0)
      configured_end = 10.days.from_now.change(usec: 0)
      mixed_event = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Mixed Cutoff Event", max_capacity: 100, starts_at: configured_start, ends_at: configured_end)
      regular_ga = create(:ticket_type, event: mixed_event, name: "Regular GA", price_cents: 0, quantity_available: 50)
      pass_type = create(:ticket_type, event: mixed_event, name: "Early Pass", price_cents: 0, quantity_available: 20,
        sales_end_at: configured_end)
      extended_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Extended Night", max_capacity: 50, starts_at: 18.days.from_now, ends_at: 18.days.from_now + 3.hours)
      link_nights(pass_type, [extended_night])

      travel_to(12.days.from_now) do
        expect(mixed_event.reload.sales_open?).to be(true)
        expect(pass_type.on_sale?).to be(false)
        expect(regular_ga.on_sale?).to be(true)
        expect(Event.discoverable_base.where(id: mixed_event.id)).to exist

        # Preserves regular ticket type's own sales window when it has closed
        regular_ga.update_columns(sales_end_at: configured_end)
        expect(Event.discoverable_base.where(id: mixed_event.id)).not_to exist
      end
    end

    it "allows completing a pass-only event once all included nights complete even before configured ends_at, while keeping ends_at for non-pass-only events" do
      pass_only = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Early Finished Pass", max_capacity: 50, starts_at: 5.days.ago, ends_at: 5.days.from_now)
      finished_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Finished Night", max_capacity: 20, starts_at: 4.days.ago, ends_at: 2.days.ago)
      pt = create(:ticket_type, event: pass_only, name: "Early Pass TT", price_cents: 0, quantity_available: 10)
      link_nights(pt, [finished_night])
      EventLifecycle.call(event: finished_night, action: :complete, actor: owner, at: Time.current)

      expect { EventLifecycle.call(event: pass_only, action: :complete, actor: owner, at: Time.current) }.not_to raise_error
      expect(pass_only.reload).to be_completed

      # Non-pass-only (mixed) event still cannot complete before its configured ends_at
      mixed_event = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Mixed Still Running", max_capacity: 50, starts_at: 5.days.ago, ends_at: 5.days.from_now)
      create(:ticket_type, event: mixed_event, name: "Regular GA", price_cents: 0, quantity_available: 10)
      mixed_pass_tt = create(:ticket_type, event: mixed_event, name: "Mixed Pass TT", price_cents: 0, quantity_available: 10)
      link_nights(mixed_pass_tt, [finished_night])

      expect { EventLifecycle.call(event: mixed_event, action: :complete, actor: owner, at: Time.current) }
        .to raise_error(EventLifecycle::TransitionError, /before it ends/)
    end

    it "omits pass parent PDFs, attaches <= 2 pass child PDFs, and omits per-night PDFs for > 2 active children" do
      stub_const("ENV", ENV.to_h.merge("PUBLIC_API_URL" => "https://api.hafapass.test"))

      two_night_tt = create(:ticket_type, event: pass_event, name: "Championship 2-Night", price_cents: 2500, quantity_available: 10)
      link_nights(two_night_tt, [night_1, night_2])
      two_order, = create_paid_pass_order(ticket_type: two_night_tt, email: "two@example.com")
      two_plan = TicketEmailAttachments.plan(two_order.tickets.includes(:ticket_type, :parent_ticket).to_a)
      expect(two_plan.attachments.length).to eq(2)
      expect(two_plan.complete?).to be(true)
      parent_two = two_order.tickets.find_by!(parent_ticket_id: nil)
      expect(two_plan.attachments.map { |a| a[:filename] }).not_to include("hafapass-ticket-#{parent_two.id}.pdf")

      three_night_tt = create(:ticket_type, event: pass_event, name: "Season 3-Night", price_cents: 4000, quantity_available: 10)
      link_nights(three_night_tt, [night_1, night_2, night_3])
      three_order, = create_paid_pass_order(ticket_type: three_night_tt, email: "three@example.com")
      three_plan = TicketEmailAttachments.plan(three_order.tickets.includes(:ticket_type, :parent_ticket).to_a)
      expect(three_plan.attachments).to eq([])
      expect(three_plan.any?).to be(false)
    end
  end

  describe "5. OrganizerSalesQuery & OrganizerSalesExport Pass Child Support" do
    before do
      link_nights(pass_tt, [night_1, night_2])
      night_1_tt
    end

    it "labels pass children with (Pass), exports $0.00 financial columns, allows linked pass filter, and keeps orders view direct-only" do
      pass_order, pass_payment = create_paid_pass_order(email: "pass-export@example.com", name: "Pass Attendee")
      Payment.where(id: pass_payment.id).update_all(provider_environment: "live")
      # Even with a discount / promo code on the pass order, child row financial columns stay $0.00
      promo = create(:promo_code, event: pass_event, code: "PASS10")
      pass_order.update!(promo_code: promo, discount_cents: 500, total_cents: pass_order.total_cents - 500)

      direct_checkout = Commerce::OrderCreator.call(
        event: night_1,
        line_items: [{ ticket_type_id: night_1_tt.id, quantity: 1 }],
        buyer_email: "direct-export@example.com",
        buyer_name: "Direct Attendee",
        payment_required: true
      )
      Commerce::OrderLifecycle.complete!(
        direct_checkout.order,
        payment: direct_checkout.payment,
        provider_amount_cents: direct_checkout.payment.amount_cents,
        provider_currency: direct_checkout.payment.currency
      )
      direct_order = direct_checkout.order.reload
      Payment.where(id: direct_checkout.payment.id).update_all(provider_environment: "live")

      # Filtering Night 1 attendees by linked pass_tt succeeds
      get "/api/v1/organizer/events/#{night_1.id}/attendees",
        params: { ticket_type: pass_tt.id },
        headers: owner_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("attendees").pluck("attendee_name")).to eq(["Pass Attendee"])

      # Unrelated ticket_type from another event is still rejected
      other_event = create(:event, :published, organizer_profile: profile, organization: org)
      unrelated_tt = create(:ticket_type, event: other_event, name: "Unrelated")
      get "/api/v1/organizer/events/#{night_1.id}/attendees",
        params: { ticket_type: unrelated_tt.id },
        headers: owner_headers
      expect(response).to have_http_status(:unprocessable_entity)

      # Ticket-grain CSV on Night 1 exports pass child with $0.00 and "(Pass)" label
      post "/api/v1/organizer/events/#{night_1.id}/sales_exports",
        params: {
          columns: %w[name ticket_type ticket_price discount fee tax total_paid discount_promo]
        },
        headers: owner_headers
      expect(response).to have_http_status(:ok)
      rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true).index_by { |row| row["Name"] }
      expect(rows.keys).to contain_exactly("Pass Attendee", "Direct Attendee")
      expect(rows["Pass Attendee"].to_h).to include(
        "Ticket type" => "Season Pass (Pass)",
        "Ticket price" => "0.00",
        "Discount" => "0.00",
        "Fee" => "0.00",
        "Tax" => "0.00",
        "Total paid" => "0.00",
        "Discount / promo" => "0.00"
      )
      expect(rows["Direct Attendee"]["Ticket type"]).to eq("Night 1 GA")

      # Orders-grain CSV on Night 1 includes ONLY direct_order (never pass_order!)
      post "/api/v1/organizer/events/#{night_1.id}/sales_exports",
        params: { view: "orders", columns: %w[order_number total_paid] },
        headers: owner_headers
      expect(response).to have_http_status(:ok)
      order_rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
      expect(order_rows.map { |r| r["Order #"] }).to eq([direct_order.reference])
    end
  end
end
