require "rails_helper"

RSpec.describe "Event change notices" do
  include ActiveJob::TestHelper

  let(:event) do
    create(:event, :published, title: "Sunset Fiesta", timezone: "Pacific/Guam", venue_name: "Tumon Bay",
      venue_address: "1 Pale San Vitores Rd", venue_city: "Tumon", starts_at: Time.utc(2030, 11, 20, 9, 0),
      ends_at: Time.utc(2030, 11, 20, 13, 0), doors_open_at: Time.utc(2030, 11, 20, 8, 30))
  end
  let(:ticket_type) { create(:ticket_type, event: event) }
  let!(:order) { create(:order, event: event, buyer_email: "buyer@example.test", created_at: 5.days.ago) }

  before { create(:ticket, order: order, event: event, ticket_type: ticket_type) }

  def snapshot(**overrides)
    { status: event.status, starts_at: event.starts_at.iso8601, ends_at: event.ends_at.iso8601,
      doors_open_at: event.doors_open_at.iso8601, venue_name: event.venue_name,
      venue_address: event.venue_address, venue_city: event.venue_city }.merge(overrides)
  end

  def change!(type: "rescheduled", reason: "Storm warning", before: snapshot, after: snapshot, at: Time.current)
    event.event_changes.create!(change_type: type, reason: reason, before_data: before, after_data: after, occurred_at: at)
  end

  def deliveries_for(change)
    MessageDelivery.where(template: "event_change").select { |delivery| delivery.metadata["event_change_id"] == change.id }
  end

  def payload_for(delivery)
    EmailService.prepare_delivery_payload(delivery)
  end

  it "shows the old and new start in Guam time with the escaped organizer reason and a specific subject" do
    before = snapshot
    event.update!(starts_at: Time.utc(2030, 11, 21, 9, 0), ends_at: Time.utc(2030, 11, 21, 13, 0))
    change = change!(reason: "Typhoon <b>warning</b>", before: before,
      after: before.merge(starts_at: Time.utc(2030, 11, 21, 9, 0).iso8601))

    EmailService.send_event_change_notifications_async(change)
    payload = payload_for(deliveries_for(change).sole)

    expect(payload.fetch("subject")).to eq("New date for Sunset Fiesta")
    html = payload.fetch("html")
    expect(html).to include("Was: November 20, 2030 at 7:00 PM Guam time", "Now: November 21, 2030 at 7:00 PM Guam time")
    expect(html).to include("Message from the organizer: Typhoon &lt;b&gt;warning&lt;/b&gt;")
    expect(html).not_to include("<b>warning</b>")
    expect(html).to include("request a refund before November 21, 2030 at 7:00 PM Guam time")
  end

  it "describes a venue change without a refund offer" do
    change = change!(type: "venue_changed", reason: "The hall flooded",
      after: snapshot(venue_name: "Dededo Hall", venue_address: "2 Marine Corps Dr", venue_city: "Dededo"))

    EmailService.send_event_change_notifications_async(change)
    payload = payload_for(deliveries_for(change).sole)

    expect(payload.fetch("subject")).to eq("Venue change for Sunset Fiesta")
    html = payload.fetch("html")
    expect(html).to include("Was: Tumon Bay, 1 Pale San Vitores Rd, Tumon", "Now: Dededo Hall, 2 Marine Corps Dr, Dededo")
    expect(html).to include("contact HåfaPass support")
    expect(html).not_to include("request a refund")
  end

  it "says a postponed event's tickets stay valid and names the original date" do
    event.update!(status: :postponed)
    change = change!(type: "postponed", after: snapshot(status: "postponed"))

    EmailService.send_event_change_notifications_async(change)
    payload = payload_for(deliveries_for(change).sole)

    expect(payload.fetch("subject")).to eq("Sunset Fiesta is postponed")
    expect(payload.fetch("html")).to include("Your ticket stays valid while the organizer sets a new date.",
      "Original date: November 20, 2030 at 7:00 PM Guam time", "Open your order to keep your tickets or request a refund.")
  end

  it "holds schedule notices for the coalescing window but sends cancellations at once" do
    reschedule = change!(after: snapshot(starts_at: Time.utc(2030, 11, 21, 9, 0).iso8601))
    EmailService.send_event_change_notifications_async(reschedule)
    queued = enqueued_jobs.select { |job| job[:job] == MessageDeliveryJob }.last
    expect(Time.zone.at(queued.fetch(:at))).to be_within(5.seconds).of(EventChange::NOTICE_COALESCE_WINDOW.from_now)

    event.update!(status: :cancelled)
    cancellation = change!(type: "cancelled", after: snapshot(status: "cancelled"))
    EmailService.send_event_change_notifications_async(cancellation)
    queued = enqueued_jobs.select { |job| job[:job] == MessageDeliveryJob }.last
    expect(queued[:args]).to eq([deliveries_for(cancellation).sole.id])
    expect(queued[:at]).to be_nil
  end

  it "sends one notice per recipient for two edits within ten minutes, describing both" do
    allow(EmailService).to receive(:send_delivery_payload).and_return({ simulated: true })
    first = change!(reason: "Later start", after: snapshot(starts_at: Time.utc(2030, 11, 20, 10, 0).iso8601), at: 20.minutes.ago)
    second = change!(reason: "Doors fix", at: 14.minutes.ago,
      before: snapshot(starts_at: Time.utc(2030, 11, 20, 10, 0).iso8601),
      after: snapshot(starts_at: Time.utc(2030, 11, 20, 10, 0).iso8601, doors_open_at: Time.utc(2030, 11, 20, 9, 30).iso8601))
    [first, second].each { |change| EmailService.send_event_change_notifications_async(change) }

    early = deliveries_for(first).sole
    late = deliveries_for(second).sole
    MessageDeliveryJob.perform_now(early.id)
    MessageDeliveryJob.perform_now(late.id)

    expect(early.reload).to have_attributes(status: "cancelled", attempts: 0)
    expect(late.reload).to be_sent
    expect(EmailService).to have_received(:send_delivery_payload).once
    html = late.outbound_payload.fetch("html")
    expect(html).to include("Was: November 20, 2030 at 7:00 PM Guam time", "Now: November 20, 2030 at 8:00 PM Guam time")
    expect(html).to include("Now: November 20, 2030 at 7:30 PM Guam time")
    expect(html).to include("Message from the organizer: Later start", "Message from the organizer: Doors fix")
    expect(late.outbound_payload.fetch("subject")).to eq("New date for Sunset Fiesta")
  end

  it "sends separate notices for edits more than ten minutes apart" do
    first = change!(at: 30.minutes.ago, after: snapshot(starts_at: Time.utc(2030, 11, 20, 10, 0).iso8601))
    second = change!(at: 5.minutes.ago, after: snapshot(starts_at: Time.utc(2030, 11, 20, 11, 0).iso8601))

    expect(first.superseded_notice?).to be(false)
    expect(second.superseded_notice?).to be(false)
    expect(second.notice_burst).to eq([second])
  end

  it "notifies each transferred ticket holder once, without duplicating buyers" do
    holder = create(:user, email: "holder@example.test")
    second_order = create(:order, event: event, buyer_email: "second@example.test")
    [order, second_order].each do |paid|
      create(:ticket, order: paid, event: event, ticket_type: ticket_type, holder_user: holder, holder_email: "Holder@example.test")
    end
    buyer_held = create(:user, email: "second@example.test")
    create(:ticket, order: order, event: event, ticket_type: ticket_type, holder_user: buyer_held,
      holder_email: "second@example.test")
    change = change!(after: snapshot(starts_at: Time.utc(2030, 11, 21, 9, 0).iso8601))

    EmailService.send_event_change_notifications_async(change)
    EmailService.send_event_change_notifications_async(change)

    deliveries = deliveries_for(change)
    expect(deliveries.map(&:recipient)).to contain_exactly("buyer@example.test", "second@example.test", "holder@example.test")
    holder_delivery = deliveries.find { |delivery| delivery.recipient == "holder@example.test" }
    expect(holder_delivery.metadata).to include("audience" => "holder")
    html = payload_for(holder_delivery).fetch("html")
    expect(html).to include("/my-tickets", "Now: November 21, 2030 at 7:00 PM Guam time")
    expect(html).not_to include("guest_token", "request a refund", "Review order")
  end

  describe "net change across a burst of edits" do
    let(:seven_pm) { Time.utc(2030, 11, 20, 9, 0) }

    before { allow(EmailService).to receive(:send_delivery_payload).and_return({ simulated: true }) }

    # Applies each start time to the event in turn, recording a change for
    # each edit the way the organizer endpoint does.
    def edit_starts!(*times, from: 6.minutes.ago, step: 2.minutes)
      times.each_with_index.map do |time, index|
        before = snapshot
        event.update!(starts_at: time, doors_open_at: time - 30.minutes, ends_at: time + 4.hours)
        change!(reason: "Edit #{index + 1}", before: before, after: snapshot, at: from + (step * index))
      end
    end

    def deliver_all!(changes)
      changes.each { |change| EmailService.send_event_change_notifications_async(change) }
      changes.flat_map { |change| deliveries_for(change) }.each { |delivery| MessageDeliveryJob.perform_now(delivery.id) }
    end

    it "sends nothing and offers no refund when a start time is moved and put back" do
      changes = edit_starts!(seven_pm - 12.hours, seven_pm)

      deliver_all!(changes)

      expect(changes.flat_map { |change| deliveries_for(change) }.map { |delivery| delivery.reload.status }).to all(eq("cancelled"))
      expect(EmailService).not_to have_received(:send_delivery_payload)
      changes.each do |change|
        expect(EventChangeRefundEligibility.call(order: order, change: change)).to have_attributes(
          eligible?: false, reason: "change_not_refundable")
      end
    end

    it "still offers a refund after a postponement even when the start returns to the original" do
      event.update!(status: :postponed)
      postponed = change!(type: "postponed", before: snapshot(status: "published"), after: snapshot, at: 3.days.ago)
      event.update!(status: :published)

      expect(EventChangeRefundEligibility.call(order: order, change: postponed)).to be_eligible
    end

    it "sends one notice from the first start to the last and offers a refund" do
      changes = edit_starts!(seven_pm + 1.hour, seven_pm + 2.hours)

      deliver_all!(changes)

      sent = changes.flat_map { |change| deliveries_for(change) }.select { |delivery| delivery.reload.sent? }
      expect(sent.length).to eq(1)
      html = sent.sole.outbound_payload.fetch("html")
      expect(html).to include("Was: November 20, 2030 at 7:00 PM Guam time", "Now: November 20, 2030 at 9:00 PM Guam time")
      expect(html).not_to include("8:00 PM")
      expect(html).to include("request a refund before November 20, 2030 at 9:00 PM Guam time")
      expect(EventChangeRefundEligibility.call(order: order, change: changes.last)).to be_eligible
    end

    it "compares an order placed partway through a burst with the event as it was bought" do
      first, = edit_starts!(seven_pm + 1.hour, from: 8.minutes.ago)
      mid = create(:order, event: event, buyer_email: "mid@example.test", created_at: 7.minutes.ago)
      create(:ticket, order: mid, event: event, ticket_type: ticket_type)
      back = edit_starts!(seven_pm, from: 6.minutes.ago).sole

      deliver_all!([first, back])

      mid_delivery = deliveries_for(back).find { |delivery| delivery.order_id == mid.id }
      expect(mid_delivery.reload).to be_sent
      expect(mid_delivery.outbound_payload.fetch("html")).to include(
        "Was: November 20, 2030 at 8:00 PM Guam time", "Now: November 20, 2030 at 7:00 PM Guam time")
      expect(deliveries_for(back).find { |delivery| delivery.order_id == order.id }.reload).to be_cancelled
      expect(EventChangeRefundEligibility.call(order: mid, change: back)).to be_eligible
      expect(EventChangeRefundEligibility.call(order: order, change: back)).not_to be_eligible
    end
  end
end
