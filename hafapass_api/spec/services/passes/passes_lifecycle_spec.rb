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
      order, _payment = create_paid_pass_order(quantity: 2)
      parents = order.tickets.where(parent_ticket_id: nil).order(:id).to_a
      parent1, parent2 = parents
      p1_children = parent1.child_tickets.order(:id).to_a
      p2_children = parent2.child_tickets.order(:id).to_a

      expect(pass_tt.reload.quantity_sold).to eq(2)
      p1_versions_before = [parent1, *p1_children].map(&:scan_credential_version)

      refund = Commerce::RefundCreator.call(
        order: order,
        tickets: [parent1],
        reason: "requested_by_customer",
        requested_by: owner,
        idempotency_key: "unused-pass-parent-1"
      )

      expect(refund).to be_succeeded
      expect(order.reload).to be_partially_refunded
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
        "Pass has already been used on one or more nights; use an organizer custom-amount refund or contact support"
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

      # Pass Event ends_at automatically extended to match rescheduled Night 1!
      expect(pass_event.reload.ends_at).to be_within(1.second).of(new_end)

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

    it "auto-extends pass_event.ends_at when adding a later night via TicketTypesController" do
      late_night = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Playoffs Final", max_capacity: 20, starts_at: 20.days.from_now, ends_at: 20.days.from_now + 4.hours)

      patch "/api/v1/organizer/events/#{pass_event.id}/ticket_types/#{pass_tt.id}",
        params: { included_event_ids: [night_1.id, night_2.id, late_night.id] },
        headers: owner_headers,
        as: :json
      expect(response).to have_http_status(:ok)
      expect(pass_event.reload.ends_at).to be_within(1.second).of(late_night.ends_at)
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
      admitted_order, = create_paid_pass_order(email: "admitted-pass@example.com", name: "Admitted Pass Fan")
      admitted_child = admitted_order.tickets.find_by!(event: night_1)
      admitted_child.check_in!
      expect(admitted_child.reload).to be_checked_in

      EventLifecycle.call(event: night_1, action: :cancel, actor: owner, reason: "Mid-game power outage")

      # Admitted ticket stays checked_in (not cancelled) while holder still receives the cancellation notice
      expect(admitted_child.reload).to be_checked_in
      pass_deliveries = MessageDelivery.where(template: "pass_event_change", event: night_1)
      expect(pass_deliveries.pluck(:recipient)).to eq(["admitted-pass@example.com"])
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

    it "skips completed/cancelled pass events, ignores cancelled nights, and bypasses unrelated pass validations in SyncPassEndDate" do
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

      expect(pass_event.reload.ends_at).to be_within(1.second).of(new_end)
      expect(completed_pass.reload.ends_at).to be_within(1.second).of(5.days.from_now)
    end

    it "rechecks linked pass event IDs under lock and retries on LockSetChanged in Organizer::EventsController#update" do
      late_linked_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Newly Linked Pass", max_capacity: 50, starts_at: 2.days.from_now, ends_at: 5.days.from_now)
      late_linked_tt = create(:ticket_type, event: late_linked_pass, name: "Late Linked TT", price_cents: 2500, quantity_available: 10)
      TicketTypeIncludedEvent.create!(ticket_type: late_linked_tt, included_event: night_1, position: 0)

      # Simulate late_linked_pass being linked right after the first pre-lock lookup:
      # call 1 (pre-lock) omits late_linked_pass.id; call 2 (under-lock recheck) sees it
      # and raises LockSetChanged before saving; attempt 2 locks all three events in sorted order.
      lookup_calls = 0
      allow(Passes::Locking).to receive(:linked_pass_event_ids).and_wrap_original do |original, ev|
        lookup_calls += 1
        ids = original.call(ev)
        lookup_calls == 1 ? (ids - [late_linked_pass.id]) : ids
      end

      lock_attempts = []
      allow(Passes::Locking).to receive(:lock_events!).and_wrap_original do |original, events|
        locked = original.call(events)
        lock_attempts << locked.map(&:id)
        locked
      end

      expect(Passes::SyncPassEndDate).to receive(:for_included_event!).once.and_call_original

      new_start = 19.days.from_now.change(usec: 0)
      new_end = new_start + 3.hours
      patch "/api/v1/organizer/events/#{night_1.id}",
        params: { starts_at: new_start.iso8601, ends_at: new_end.iso8601, change_reason: "Reschedule with concurrent pass link" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)

      expect(lock_attempts.length).to eq(2)
      expect(lock_attempts.first).to eq([night_1.id, pass_event.id].sort)
      expect(lock_attempts.second).to eq([night_1.id, pass_event.id, late_linked_pass.id].sort)
      expect(pass_event.reload.ends_at).to be_within(1.second).of(new_end)
      expect(late_linked_pass.reload.ends_at).to be_within(1.second).of(new_end)
    end

    it "recomputes pass_event.ends_at downward when a storm-extended night is moved earlier" do
      far_start = 18.days.from_now.change(usec: 0)
      far_end = far_start + 3.hours
      patch "/api/v1/organizer/events/#{night_2.id}",
        params: { starts_at: far_start.iso8601, ends_at: far_end.iso8601, change_reason: "Typhoon delay" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)
      expect(pass_event.reload.ends_at).to be_within(1.second).of(far_end)

      earlier_start = 6.days.from_now.change(usec: 0)
      earlier_end = earlier_start + 3.hours
      patch "/api/v1/organizer/events/#{night_2.id}",
        params: { starts_at: earlier_start.iso8601, ends_at: earlier_end.iso8601, change_reason: "Moved back earlier" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)
      expect(pass_event.reload.ends_at).to be_within(1.second).of(earlier_end)
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

      # Once pub_night completes, draft & cancelled nights do NOT block pass completion
      pub_night.update_columns(status: Event.statuses.fetch("completed"))
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
      expect(upcoming_ids).to include(parent.id, n15_child.id)
      expect(upcoming_ids).not_to include(n1_child.id)
      parent_json = response.parsed_body.fetch("tickets").find { |t| t["id"] == parent.id }
      expect(parent_json["upcoming"]).to be(true)
      expect(Time.zone.parse(parent_json.dig("event", "ends_at"))).to be_within(1.second).of(n15.ends_at)

      get "/api/v1/me/tickets", params: { tab: "past" }, headers: auth_headers(buyer)
      expect(response.parsed_body.fetch("tickets").pluck("id")).to eq([n1_child.id])

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

    it "recomputes sync-extended ends_at on latest night cancellation so sales and discovery close after surviving nights end" do
      synced_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Synced Tourney Pass", max_capacity: 50, starts_at: 2.days.from_now, ends_at: 5.days.from_now)
      synced_night_1 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Synced Night 1", max_capacity: 20, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
      synced_night_2 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Synced Night 2", max_capacity: 20, starts_at: 10.days.from_now, ends_at: 10.days.from_now + 3.hours)
      synced_tt = create(:ticket_type, event: synced_pass, name: "Synced Pass TT", price_cents: 0, quantity_available: 10)
      link_nights(synced_tt, [synced_night_1, synced_night_2])

      # SyncPassEndDate naturally extended synced_pass.ends_at to Night 2's end
      expect(synced_pass.reload.ends_at).to be_within(1.second).of(synced_night_2.ends_at)
      expect(Event.discoverable_base.where(id: synced_pass.id)).to exist

      # Cancel Night 2 through EventLifecycle -> synced_pass.ends_at drops back to Night 1's end
      EventLifecycle.call(event: synced_night_2, action: :cancel, actor: owner, reason: "Storm cancelled final night")
      expect(synced_pass.reload.ends_at).to be_within(1.second).of(synced_night_1.ends_at)

      # After Night 1 ends (and before Night 2's former end), sales and discovery are closed
      travel_to(3.days.from_now) do
        expect(synced_pass.reload.sales_open?).to be(false)
        expect(Event.discoverable_base.where(id: synced_pass.id)).not_to exist
      end
    end

    it "resets extended ends_at, closes sales/discovery, and allows completion when the final surviving included night is cancelled" do
      pass_start = 2.days.from_now.change(usec: 0)
      final_pass = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Final Night Pass", max_capacity: 50, starts_at: pass_start, ends_at: 5.days.from_now)
      cancelled_n1 = create(:event, :cancelled, organizer_profile: profile, organization: org,
        title: "Already Cancelled Night 1", max_capacity: 20, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
      surviving_n2 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Surviving Night 2", max_capacity: 20, starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
      final_tt = create(:ticket_type, event: final_pass, name: "Final Pass TT", price_cents: 0, quantity_available: 10)
      link_nights(final_tt, [cancelled_n1, surviving_n2])

      # Reschedule the final surviving night to day 18 so SyncPassEndDate extends final_pass.ends_at to day 18
      day_18_start = 18.days.from_now.change(usec: 0)
      day_18_end = day_18_start + 3.hours
      patch "/api/v1/organizer/events/#{surviving_n2.id}",
        params: { starts_at: day_18_start.iso8601, ends_at: day_18_end.iso8601, change_reason: "Typhoon reschedule to day 18" },
        headers: owner_headers
      expect(response).to have_http_status(:ok)
      expect(final_pass.reload.ends_at).to be_within(1.second).of(day_18_end)
      expect(final_pass.sales_open?).to be(true)
      expect(Event.discoverable_base.where(id: final_pass.id)).to exist

      # Cancel the final surviving night through EventLifecycle
      EventLifecycle.call(event: surviving_n2, action: :cancel, actor: owner, reason: "Final night cancelled")

      final_pass.reload
      expect(final_pass.ends_at).to be_within(2.seconds).of(pass_start)
      expect(final_pass.ends_at).to be < day_18_start
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
