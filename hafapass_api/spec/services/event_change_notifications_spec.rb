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
    change = change!(reason: "Typhoon <b>warning</b>",
      after: snapshot(starts_at: Time.utc(2030, 11, 21, 9, 0).iso8601))

    EmailService.send_event_change_notifications_async(change)
    payload = payload_for(deliveries_for(change).sole)

    expect(payload.fetch("subject")).to eq("New date for Sunset Fiesta")
    html = payload.fetch("html")
    expect(html).to include("Was: November 20, 2030 at 7:00 PM Guam time", "Now: November 21, 2030 at 7:00 PM Guam time")
    expect(html).to include("Message from the organizer: Typhoon &lt;b&gt;warning&lt;/b&gt;")
    expect(html).not_to include("<b>warning</b>")
    expect(html).to include("request a refund before November 20, 2030 at 7:00 PM Guam time")
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
end
