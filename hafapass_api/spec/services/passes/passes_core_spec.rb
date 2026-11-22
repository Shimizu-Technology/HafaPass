# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Multi-night passes core behavior" do
  let(:owner) { create(:user) }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:org) { profile.organization }
  let(:pass_event) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "FD Tourney Pass", max_capacity: 100, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
  end
  let(:night_1) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "Night 1", max_capacity: 10, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
  end
  let(:night_2) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "Night 2", max_capacity: 10, starts_at: 3.days.from_now, ends_at: 3.days.from_now + 3.hours)
  end
  let(:pass_tt) do
    create(:ticket_type, event: pass_event, name: "Season Pass", price_cents: 5000, quantity_available: 50, max_per_buyer: 2)
  end
  let(:night_1_tt) do
    create(:ticket_type, event: night_1, name: "Night 1 GA", price_cents: 1000, quantity_available: 10)
  end
  let(:night_2_tt) do
    create(:ticket_type, event: night_2, name: "Night 2 GA", price_cents: 1000, quantity_available: 10)
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent) do |order, **|
      OpenStruct.new(id: "pi_test_#{order.id}", client_secret: "cs_test_#{order.id}",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"])
    end
  end

  describe TicketTypeIncludedEvent do
    it "syncs ticket_type.is_pass on create and destroy" do
      expect(pass_tt.is_pass?).to be(false)
      link = described_class.create!(ticket_type: pass_tt, included_event: night_1, position: 0)
      expect(pass_tt.reload.is_pass?).to be(true)
      expect(pass_tt.pass?).to be(true)

      link.destroy!
      expect(pass_tt.reload.is_pass?).to be(false)
    end

    it "rejects cross-organization events, self-loops, negative positions, seated events, and nested passes" do
      other_event = create(:event, :published)
      expect(described_class.new(ticket_type: pass_tt, included_event: other_event)).not_to be_valid
      expect(described_class.new(ticket_type: pass_tt, included_event: pass_event)).not_to be_valid
      expect(described_class.new(ticket_type: pass_tt, included_event: night_1, position: -1)).not_to be_valid

      venue = create(:venue)
      night_1.update!(venue: venue)
      create(:event_seating_configuration, event: night_1)
      expect(described_class.new(ticket_type: pass_tt, included_event: night_1.reload)).not_to be_valid

      # Nested pass checks (both directions)
      described_class.create!(ticket_type: pass_tt, included_event: night_2, position: 0)
      night_3 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night 3", max_capacity: 10, starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
      # night_2 is already included in pass_tt, so night_2 cannot itself have a pass
      expect(described_class.new(ticket_type: night_2_tt, included_event: night_3)).not_to be_valid
      # pass_event already has a pass ticket type, so night_3 cannot include pass_event
      night_3_tt = create(:ticket_type, event: night_3, name: "Night 3 Pass", price_cents: 2000, quantity_available: 10)
      expect(described_class.new(ticket_type: night_3_tt, included_event: pass_event)).not_to be_valid
    end

    it "refuses removal once passes have been sold or actively held (including lapsed-but-active holds)" do
      link = described_class.create!(ticket_type: pass_tt, included_event: night_1, position: 0)
      pass_tt.update!(quantity_sold: 1)
      expect(link.destroy).to be(false)
      expect(link.errors[:base]).to include(/cannot be removed/i)

      pass_tt.update!(quantity_sold: 0)
      order = create(:order, :pending, event: pass_event)
      item = create(:order_item, order: order, ticket_type: pass_tt)
      hold = InventoryHold.create!(order: order, order_item: item, event: pass_event, ticket_type: pass_tt,
        quantity: 1, expires_at: 10.minutes.from_now)
      expect(link.destroy).to be(false)

      # Lapsed-but-still-active hold (eligible for late completion) also blocks removal and adding new nights
      hold.update!(expires_at: 5.minutes.ago)
      expect(link.destroy).to be(false)
      added = described_class.new(ticket_type: pass_tt.reload, included_event: night_2, position: 1)
      expect(added).not_to be_valid
      expect(added.errors[:base]).to include(/in progress/i)
    end

    it "refuses converting an existing sold, ticketed, or held non-pass ticket type into a pass" do
      regular_tt = create(:ticket_type, event: pass_event, name: "Regular GA", price_cents: 1000, quantity_available: 10)
      regular_tt.update!(quantity_sold: 1)
      link = described_class.new(ticket_type: regular_tt, included_event: night_1, position: 0)
      expect(link).not_to be_valid
      expect(link.errors[:ticket_type]).to include(/cannot be converted/i)

      # Even when quantity_sold is 0, existing ticket history blocks conversion
      regular_tt.update!(quantity_sold: 0)
      order = create(:order, :completed, event: pass_event)
      item = create(:order_item, order: order, ticket_type: regular_tt)
      create(:ticket, order: order, order_item: item, event: pass_event, ticket_type: regular_tt, status: :cancelled)
      expect(described_class.new(ticket_type: regular_tt, included_event: night_1, position: 0)).not_to be_valid

      # Active hold on a fresh non-pass ticket type also blocks conversion
      held_tt = create(:ticket_type, event: pass_event, name: "Held GA", price_cents: 1000, quantity_available: 10)
      pending_order = create(:order, :pending, event: pass_event)
      pending_item = create(:order_item, order: pending_order, ticket_type: held_tt)
      InventoryHold.create!(order: pending_order, order_item: pending_item, event: pass_event, ticket_type: held_tt,
        quantity: 1, expires_at: 10.minutes.from_now)
      expect(described_class.new(ticket_type: held_tt, included_event: night_1, position: 0)).not_to be_valid
    end
  end

  describe "Issuance, capacity across all 6 sites, buyer limits, admissions, and safety fences" do
    before do
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_1, position: 0)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_2, position: 1)
      pass_tt.reload
      night_1_tt
      night_2_tt
    end

    it "issues parent + 1 child per included night idempotently and enforces max_per_buyer on parent passes only" do
      result1 = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "fan@example.com",
        buyer_name: "Season Fan",
        payment_required: false
      )
      order1 = result1.order
      parent1 = order1.tickets.find_by!(parent_ticket_id: nil)
      children1 = order1.tickets.where(parent_ticket_id: parent1.id).order(:event_id)

      expect(parent1.pass_parent?).to be(true)
      expect(parent1.pass_child?).to be(false)
      expect(children1.count).to eq(2)
      expect(children1.map(&:event_id)).to contain_exactly(night_1.id, night_2.id)
      expect(children1).to all(have_attributes(order_item_id: nil, attendee_name: "Season Fan", attendee_email: "fan@example.com"))
      expect(children1.map(&:qr_code)).to all(be_present)

      # Re-running Passes::Issuance is idempotent
      expect(Passes::Issuance.call(order: order1, parent_ticket: parent1)).to be_empty
      expect(order1.tickets.where(parent_ticket_id: parent1.id).count).to eq(2)

      # Buyer limit is 2: buying a 2nd pass succeeds (1st pass counted as 1, NOT 3!)
      result2 = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "fan@example.com",
        buyer_name: "Season Fan",
        payment_required: false
      )
      expect(result2.order).to be_completed

      # 3rd pass is blocked by max_per_buyer: 2
      expect do
        Commerce::OrderCreator.call(
          event: pass_event,
          line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
          buyer_email: "fan@example.com",
          buyer_name: "Season Fan",
          payment_required: false
        )
      end.to raise_error(Commerce::OrderCreator::CheckoutError, /Purchase limit is 2/)

      # release_inventory! on child does NOT decrement quantity_sold
      expect { children1.first.release_inventory! }.not_to change { pass_tt.reload.quantity_sold }
    end

    it "enforces night capacity across all 6 sites (discoverable, remaining_capacity, publish_checklist, validation, checkout, late completion)" do
      night_1.update!(max_capacity: 2)
      night_1_tt.update!(quantity_available: 2)

      # Site 2: remaining_capacity
      expect(night_1.remaining_capacity).to eq(2)
      expect(Event.discoverable.pluck(:id)).to include(night_1.id)

      # Pending paid pass hold reserves night_1 capacity
      pending = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "hold@example.com",
        buyer_name: "Hold Buyer",
        payment_required: true
      )
      expect(night_1.remaining_capacity).to eq(1)

      # Complete a 2nd pass -> night_1 is now at 2/2 (1 hold + 1 child ticket)
      Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "paid@example.com",
        buyer_name: "Paid Buyer",
        payment_required: false
      )
      expect(night_1.remaining_capacity).to eq(0)

      # Site 1: Event.discoverable excludes saturated night_1
      expect(Event.discoverable.pluck(:id)).not_to include(night_1.id)

      # Site 3: publish_checklist capacity fails when configured_inventory (2) + pass_committed (2) > max_capacity (2)
      cap_item = night_1.publish_checklist.find { |item| item[:code] == "capacity" }
      expect(cap_item[:complete]).to be(false)
      # Pass event's own checklist stays clean
      pass_cap_item = pass_event.publish_checklist.find { |item| item[:code] == "capacity" }
      expect(pass_cap_item[:complete]).to be(true)

      # Site 4: Event#capacity_covers_committed_inventory refuses reducing max_capacity below committed (2)
      expect(night_1.update(max_capacity: 1)).to be(false)
      expect(night_1.errors[:max_capacity]).to be_present
      night_1.reload

      # Site 5: OrderCreator rejects both night_1 daily checkout AND another pass checkout
      expect do
        Commerce::OrderCreator.call(
          event: night_1,
          line_items: [{ ticket_type_id: night_1_tt.id, quantity: 1 }],
          buyer_email: "daily@example.com",
          buyer_name: "Daily",
          payment_required: false
        )
      end.to raise_error(Commerce::OrderCreator::CheckoutError, /capacity/i)

      expect do
        Commerce::OrderCreator.call(
          event: pass_event,
          line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
          buyer_email: "pass3@example.com",
          buyer_name: "Pass 3",
          payment_required: false
        )
      end.to raise_error(Commerce::OrderCreator::CheckoutError, /Night 1/)

      # Site 6: Late completion checks included night capacity when hold has lapsed
      pending.order.inventory_holds.update_all(expires_at: 2.minutes.ago)
      # Fill the freed spot on night_1 with a daily ticket
      Commerce::OrderCreator.call(
        event: night_1,
        line_items: [{ ticket_type_id: night_1_tt.id, quantity: 1 }],
        buyer_email: "fill@example.com",
        buyer_name: "Filler",
        payment_required: false
      )
      expect(night_1.remaining_capacity).to eq(0)

      # Now late completion of the lapsed pass order must NOT succeed (night_1 has 0 capacity)
      result = Commerce::OrderLifecycle.complete!(
        pending.order,
        payment: pending.payment,
        provider_amount_cents: pending.payment.amount_cents,
        provider_currency: pending.payment.currency,
        late_completion: true
      )
      expect(result).to eq(:unchanged)
      expect(pending.order.reload).to be_expired
    end

    it "enforces unified admissions eligibility, counts, manifest, door list, and refund/transfer guards" do
      order = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "gate@example.com",
        buyer_name: "Gate Attendee",
        payment_required: false
      ).order
      parent = order.tickets.find_by!(parent_ticket_id: nil)
      night_1_child = order.tickets.find_by!(event: night_1)

      # Pass container cannot be checked in
      expect(parent.admission_block_reason).to eq("pass_container")
      expect(parent.admission_allowed?).to be(false)
      expect { parent.check_in! }.to raise_error(
        Ticket::AdmissionError,
        "Multi-night pass containers cannot be scanned directly; scan the ticket for tonight's event"
      )

      # Pass event manifest & counts & door list exclude pass parent
      pass_manifest = Admissions::ManifestBuilder.call(event: pass_event, actor: owner)
      expect(pass_manifest.payload.fetch("tickets")).to be_empty
      expect(Admissions::Counts.call(event: pass_event)).to include(total: 0, issued: 0, eligible_unadmitted: 0)

      # Night 1 manifest & counts include pass child
      night_manifest = Admissions::ManifestBuilder.call(event: night_1, actor: owner)
      expect(night_manifest.payload.fetch("tickets").map { |t| t["ticket_id"] }).to eq([night_1_child.id])
      expect(night_manifest.payload.fetch("tickets").first["state"]).to eq("valid")
      expect(Admissions::Counts.call(event: night_1)).to include(total: 1, issued: 1, admitted: 0, eligible_unadmitted: 1)

      # DoorListPdf excludes pass parent and includes pass child
      pass_pdf_text = PDF::Reader.new(StringIO.new(Admissions::DoorListPdf.new(pass_event).generate)).pages.map(&:text).join
      expect(pass_pdf_text).not_to include("Gate Attendee")
      night_pdf_text = PDF::Reader.new(StringIO.new(Admissions::DoorListPdf.new(night_1).generate)).pages.map(&:text).join
      expect(night_pdf_text).to include("Gate Attendee")

      # Pending refund on parent pass blocks night_1_child in model, manifest, counts, and check_in!
      payment = create(:payment, order: order, status: :succeeded, amount_cents: order.total_cents)
      refund = create(:refund, order: order, payment: payment, status: :pending, amount_cents: 1000)
      refund.refund_tickets.create!(ticket: parent, amount_cents: 1000)

      expect(night_1_child.reload.refund_pending?).to be(true)
      expect(night_1_child.admission_block_reason).to eq("refund_pending")
      expect(night_1_child.admission_allowed?).to be(false)
      expect { night_1_child.check_in! }.to raise_error(Ticket::AdmissionError, /refund is pending/)
      expect(Admissions::Counts.call(event: night_1)).to include(total: 1, issued: 1, eligible_unadmitted: 0)
      refreshed_manifest = Admissions::ManifestBuilder.call(event: night_1, actor: owner)
      expect(refreshed_manifest.payload.fetch("tickets").first["state"]).to eq("refund_pending")

      # Clear pending refund -> night_1_child can be admitted via Reconciler
      refund.refund_tickets.update_all(released_at: Time.current)
      refund.update!(status: :failed)
      device = Admissions::DeviceRegistrar.call(event: night_1, user: owner, identifier: "gate-pass", name: "Gate")
      valid_manifest = Admissions::ManifestBuilder.call(event: night_1, actor: owner)
      results = Admissions::Reconciler.call(
        device: device,
        actor: owner,
        actions: [{
          action_uuid: SecureRandom.uuid,
          sequence: 1,
          kind: "admit",
          source: "online",
          ticket_id: night_1_child.id,
          credential_hash: Digest::SHA256.hexdigest(night_1_child.scan_credential),
          manifest_version: valid_manifest.version,
          occurred_at: Time.current.iso8601(6)
        }]
      )
      expect(results.sole.action).to have_attributes(result: "accepted", reason_code: "admitted")
      expect(Admissions::Counts.call(event: night_1)).to include(total: 1, admitted: 1, eligible_unadmitted: 0)

      # Safety fences: RefundCreator rejects both pass child and selected pass parent
      night_2_child = order.tickets.find_by!(event: night_2)
      expect do
        Commerce::RefundCreator.call(
          order: order,
          tickets: [night_2_child],
          reason: "requested_by_customer",
          requested_by: owner
        )
      end.to raise_error(Commerce::RefundCreator::RefundError, "Refund the parent pass instead of a single night")
      expect do
        Commerce::RefundCreator.call(
          order: order,
          tickets: [parent],
          reason: "requested_by_customer",
          requested_by: owner
        )
      end.to raise_error(Commerce::RefundCreator::RefundError, /order level/i)

      # Safety fences: TicketTransfers::Manager rejects both pass parent and pass child
      pass_event.update!(transfers_enabled: true)
      night_2.update!(transfers_enabled: true)
      expect do
        TicketTransfers::Manager.create!(ticket: parent, recipient_email: "other@example.com")
      end.to raise_error(TicketTransfers::Manager::TransferError, "Multi-night passes cannot be transferred")
      expect do
        TicketTransfers::Manager.create!(ticket: night_2_child, recipient_email: "other@example.com")
      end.to raise_error(TicketTransfers::Manager::TransferError, "Multi-night passes cannot be transferred")
    end

    it "allows whole-order pass refund cancelling parent and all children while failing closed on orphaned children" do
      allow(EmailService).to receive(:send_refund_notification_async)
      allow(StripeService).to receive(:refund_payment) do |_pi, amount_cents:, **|
        OpenStruct.new(id: "re_pass_#{SecureRandom.hex(6)}", status: "succeeded", amount: amount_cents, currency: "usd")
      end

      checkout = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "refund-pass@example.com",
        buyer_name: "Refund Fan",
        payment_required: true
      )
      order = checkout.order
      payment = checkout.payment
      Commerce::OrderLifecycle.complete!(order, payment: payment,
        provider_amount_cents: payment.amount_cents, provider_currency: payment.currency)
      order.reload
      expect(pass_tt.reload.quantity_sold).to eq(1)
      expect(order.tickets.count).to eq(3)

      # Whole-order refund (tickets: nil) cancels parent + all children and decrements quantity_sold once
      refund = Commerce::RefundCreator.call(
        order: order,
        reason: "requested_by_customer",
        requested_by: owner
      )
      expect(refund).to be_succeeded
      expect(order.reload).to be_refunded
      expect(order.tickets.pluck(:status).uniq).to eq(["cancelled"])
      expect(pass_tt.reload.quantity_sold).to eq(0)

      # Backstop: if a parent pass is cancelled while a child stays issued, admission/scan/manifest/counts all block it
      order2 = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "orphan@example.com",
        buyer_name: "Orphan Fan",
        payment_required: false
      ).order
      parent2 = order2.tickets.find_by!(parent_ticket_id: nil)
      child2 = order2.tickets.find_by!(event: night_1)
      device = Admissions::DeviceRegistrar.call(event: night_1, user: owner, identifier: "orphan-gate", name: "Gate")
      manifest_before = Admissions::ManifestBuilder.call(event: night_1, actor: owner)

      parent2.update!(status: :cancelled, cancelled_at: Time.current, cancellation_reason: "manual_backstop_test")

      expect(child2.reload.admission_block_reason).to eq("cancelled")
      expect(child2.admission_allowed?).to be(false)
      expect { child2.check_in! }.to raise_error(Ticket::AdmissionError, "Ticket is not in issued status")

      reconcile_results = Admissions::Reconciler.call(
        device: device,
        actor: owner,
        actions: [{
          action_uuid: SecureRandom.uuid,
          sequence: 1,
          kind: "admit",
          source: "online",
          ticket_id: child2.id,
          credential_hash: Digest::SHA256.hexdigest(child2.scan_credential),
          manifest_version: manifest_before.version,
          occurred_at: Time.current.iso8601(6)
        }]
      )
      expect(reconcile_results.sole.action).to have_attributes(result: "rejected", reason_code: "cancelled")

      manifest_after = Admissions::ManifestBuilder.call(event: night_1, actor: owner)
      child2_entry = manifest_after.payload.fetch("tickets").find { |entry| entry["ticket_id"] == child2.id }
      expect(child2_entry["state"]).to eq("cancelled")

      expect(Admissions::Counts.call(event: night_1)).to include(total: 0, issued: 0, eligible_unadmitted: 0)
    end

    it "retries and re-locks the updated sorted event set when included events change before locks are acquired" do
      night_3 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night 3", max_capacity: 10, starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_3, position: 2)
      locked_batches = []
      stale_read_done = false

      allow(Passes::Locking).to receive(:included_event_ids_for_ticket_type_ids).and_wrap_original do |original, **kwargs|
        if !stale_read_done
          stale_read_done = true
          [night_1.id, night_2.id]
        else
          original.call(**kwargs)
        end
      end
      allow(Passes::Locking).to receive(:lock_events!).and_wrap_original do |original, events|
        result = original.call(events)
        locked_batches << result.map(&:id)
        result
      end

      order = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "retry@example.com",
        buyer_name: "Retry Fan",
        payment_required: false
      ).order

      expected_full_set = [pass_event.id, night_1.id, night_2.id, night_3.id].sort
      expect(locked_batches.first).to eq([pass_event.id, night_1.id, night_2.id].sort)
      expect(locked_batches[1]).to eq(expected_full_set)
      expect(order.tickets.where.not(parent_ticket_id: nil).pluck(:event_id)).to contain_exactly(
        night_1.id, night_2.id, night_3.id
      )
    end

    it "retries OrderLifecycle.complete! on LockSetChanged and skips extra queries for non-pass orders" do
      pending_checkout = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "lc-retry@example.com",
        buyer_name: "Lifecycle Fan",
        payment_required: true
      )
      night_3 = create(:event, :published, organizer_profile: profile, organization: org,
        title: "Night 3", max_capacity: 10, starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
      TicketTypeIncludedEvent.insert!({
        ticket_type_id: pass_tt.id, included_event_id: night_3.id, position: 2,
        created_at: Time.current, updated_at: Time.current
      })
      stale_read_done = false
      locked_batches = []

      allow(Passes::Locking).to receive(:related_event_ids_for_pass_order).and_wrap_original do |original, *args|
        if !stale_read_done
          stale_read_done = true
          [night_1.id, night_2.id]
        else
          original.call(*args)
        end
      end
      allow(Passes::Locking).to receive(:lock_events!).and_wrap_original do |original, events|
        result = original.call(events)
        locked_batches << result.map(&:id)
        result
      end

      status = Commerce::OrderLifecycle.complete!(
        pending_checkout.order,
        payment: pending_checkout.payment,
        provider_amount_cents: pending_checkout.payment.amount_cents,
        provider_currency: pending_checkout.payment.currency
      )
      expect(status).to eq(:completed)
      expect(locked_batches).to eq([
        [pass_event.id, night_1.id, night_2.id].sort,
        [pass_event.id, night_1.id, night_2.id, night_3.id].sort
      ])
      expect(pending_checkout.order.tickets.where.not(parent_ticket_id: nil).pluck(:event_id)).to contain_exactly(
        night_1.id, night_2.id, night_3.id
      )

      # Non-pass order skips extra joins/queries on order_items, inventory_holds, tickets, and ticket_type_included_events
      regular_order = create(:order, :pending, event: night_1)
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]

        queries << payload[:sql]
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        Order.transaction { Passes::Locking.lock_events_for_order!(regular_order) }
      end
      expect(queries.grep(/ticket_type_included_events|inventory_holds|order_items/)).to be_empty
    end
  end
end
