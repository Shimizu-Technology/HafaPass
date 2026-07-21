require "rails_helper"

RSpec.describe "Assigned seating lifecycle" do
  let(:organization) { create(:organization) }
  let(:actor) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, organization: organization, user: actor) }
  let(:venue) { create(:venue) }
  let(:event) do
    create(:event, :published, organization: organization, organizer_profile: profile, venue: venue,
      starts_at: 5.days.from_now, max_capacity: 6)
  end
  let!(:ticket_type) { create(:ticket_type, event: event, quantity_available: 6, price_cents: 2500) }
  let(:layout) { create(:venue_layout, organization: organization, venue: venue) }
  let!(:zone) { create(:seating_price_zone, venue_layout: layout, code: "MAIN") }
  let!(:section) { create(:seating_section, venue_layout: layout, name: "Main floor", code: "MAIN") }
  let!(:row) { create(:seating_row, seating_section: section, label: "A") }
  let!(:standard_one) { create(:venue_seat, seating_row: row, seating_price_zone: zone, label: "1", position: 1) }
  let!(:standard_two) { create(:venue_seat, seating_row: row, seating_price_zone: zone, label: "2", position: 2) }
  let!(:wheelchair) do
    create(:venue_seat, seating_row: row, seating_price_zone: zone, label: "W1", position: 3,
      accessibility_kind: :wheelchair, companion_group: "A-W1")
  end
  let!(:companion) do
    create(:venue_seat, seating_row: row, seating_price_zone: zone, label: "C1", position: 4,
      accessibility_kind: :companion, companion_group: "A-W1")
  end

  def activate!
    Seating::ConfigurationActivator.call(
      event: event,
      venue_layout: layout,
      zone_ticket_types: { zone.id => ticket_type.id },
      actor: actor
    )
  end

  it "snapshots a reusable layout and publishes a non-identifying accessible map" do
    configuration = activate!
    map = Seating::MapPresenter.call(configuration)

    expect(configuration).to be_status_active
    expect(configuration.event_seats.count).to eq(4)
    expect(ticket_type.reload.quantity_available).to eq(4)
    expect(map[:sections].first[:rows].first[:seats]).to include(
      include(display_label: "Main floor · Row A · Seat W1", accessibility_kind: "wheelchair",
        requires_accessibility_attestation: true, status: "available")
    )
    expect(map.to_json).not_to include("buyer_email", "attendee_name")
  end

  it "requires attestation and a wheelchair location for protected companion inventory" do
    configuration = activate!
    wheelchair_seat = configuration.event_seats.find_by!(venue_seat: wheelchair)
    companion_seat = configuration.event_seats.find_by!(venue_seat: companion)

    expect do
      Seating::HoldAllocator.call(event: event, event_seat_ids: [wheelchair_seat.id], accessibility_attested: false)
    end.to raise_error(Seating::HoldAllocator::HoldError, /Confirm that accessible seating is needed/)
    expect do
      Seating::HoldAllocator.call(event: event, event_seat_ids: [companion_seat.id], accessibility_attested: true)
    end.to raise_error(Seating::HoldAllocator::HoldError, /selected with their wheelchair/)

    result = Seating::HoldAllocator.call(
      event: event,
      event_seat_ids: [wheelchair_seat.id, companion_seat.id],
      accessibility_attested: true
    )
    expect(result.session.seat_holds.count).to eq(2)
  end

  it "claims the exact seat hold at checkout and issues one seat-specific ticket" do
    allow(StripeService).to receive(:payment_enabled?).and_return(false)
    configuration = activate!
    event_seat = configuration.event_seats.find_by!(venue_seat: standard_one)
    result = Seating::HoldAllocator.call(event: event, event_seat_ids: [event_seat.id], accessibility_attested: false)

    expect do
      Commerce::OrderCreator.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "buyer@example.com",
        buyer_name: "Buyer"
      )
    end.to raise_error(Commerce::OrderCreator::CheckoutError, /Select and reserve seats/)

    checkout = Commerce::OrderCreator.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com",
      buyer_name: "Buyer",
      seat_hold_token: result.token
    )
    ticket = checkout.order.tickets.first

    expect(checkout.order).to be_completed
    expect(ticket).to have_attributes(event_seat_id: event_seat.id, ticket_type_id: ticket_type.id)
    expect(ticket.seat_label).to eq("Main floor · Row A · Seat 1")
    expect(result.session.reload).to be_status_consumed
    expect(SeatAuditEvent.pluck(:action)).to include("seat_hold.created", "seat_hold.claimed", "seat_hold.consumed")
  end

  it "expires abandoned holds and makes the seat immediately reservable again" do
    configuration = activate!
    event_seat = configuration.event_seats.find_by!(venue_seat: standard_one)
    first = Seating::HoldAllocator.call(event: event, event_seat_ids: [event_seat.id], accessibility_attested: false)
    first.session.update!(expires_at: 1.minute.ago)

    ExpireSeatHoldsJob.perform_now(Time.current)
    second = Seating::HoldAllocator.call(event: event, event_seat_ids: [event_seat.id], accessibility_attested: false)

    expect(first.session.reload).to be_status_expired
    expect(second.session).to be_status_active
  end

  it "exchanges an unused ticket atomically and rotates both credentials" do
    allow(StripeService).to receive(:payment_enabled?).and_return(false)
    configuration = activate!
    original = configuration.event_seats.find_by!(venue_seat: standard_one)
    target = configuration.event_seats.find_by!(venue_seat: standard_two)
    hold = Seating::HoldAllocator.call(event: event, event_seat_ids: [original.id], accessibility_attested: false)
    checkout = Commerce::OrderCreator.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com",
      buyer_name: "Buyer",
      seat_hold_token: hold.token
    )
    ticket = checkout.order.tickets.first
    previous_versions = [ticket.scan_credential_version, ticket.display_credential_version]

    Seating::SeatExchange.call(
      ticket: ticket,
      target_event_seat: target,
      actor: nil,
      accessibility_attested: false
    )

    expect(ticket.reload.event_seat_id).to eq(target.id)
    expect([ticket.scan_credential_version, ticket.display_credential_version]).to eq(previous_versions.map { |value| value + 1 })
    expect(original.reload).to be_selectable
  end

  it "releases accessible inventory only after standard seats in a qualifying scope are sold" do
    configuration = activate!
    wheelchair_seat = configuration.event_seats.find_by!(venue_seat: wheelchair)
    configuration.event_seats.where(venue_seat: [standard_one, standard_two]).update_all(
      operational_status: EventSeat.operational_statuses[:blocked]
    )

    expect do
      Seating::AccessibleRelease.call(event: event, event_seats: [wheelchair_seat], actor: actor, reason: "Demand")
    end.to raise_error(Seating::AccessibleRelease::ReleaseError, /only after non-accessible seats sell out/)

    [standard_one, standard_two].each do |venue_seat|
      assigned = configuration.event_seats.find_by!(venue_seat: venue_seat)
      order = create(:order, event: event)
      create(:ticket, order: order, event: event, ticket_type: ticket_type, event_seat: assigned)
    end
    release = Seating::AccessibleRelease.call(
      event: event,
      event_seats: [wheelchair_seat],
      actor: actor,
      reason: "All standard seats in Main floor sold"
    ).first

    expect(release.release_scope).to eq("section")
    expect(wheelchair_seat.reload).to be_generally_released
  end

  it "enforces one active ticket per event seat at the database boundary" do
    configuration = activate!
    event_seat = configuration.event_seats.find_by!(venue_seat: standard_one)
    first_order = create(:order, event: event)
    create(:ticket, order: first_order, event: event, ticket_type: ticket_type, event_seat: event_seat)

    expect do
      Ticket.transaction(requires_new: true) do
        create(:ticket, order: create(:order, event: event), event: event,
          ticket_type: ticket_type, event_seat: event_seat)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "pauses every online and box-office sale without disabling admission" do
    activate!
    event.update!(sales_suspended_at: Time.current, sales_suspension_reason: "Safety review")

    expect(event).not_to be_sales_open
    expect(event).not_to be_has_available_inventory
  end
end
