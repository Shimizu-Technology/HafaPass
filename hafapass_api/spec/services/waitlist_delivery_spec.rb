require "rails_helper"

RSpec.describe WaitlistDelivery do
  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let(:entry) { create(:waitlist_entry, event: event) }

  before do
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
  end

  it "releases a suppressed offer immediately and exposes a retryable failure" do
    ticket = create(:ticket_type, event: event, quantity_available: 3)
    offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ticket)
    delivery = MessageDelivery.find_by!(template: "waitlist_offer", idempotency_key: "waitlist-offer/#{offer.id}")
    event.organization.update!(marketing_address_certified_at: nil)

    MessageDeliveryJob.perform_now(delivery.id)

    expect(delivery.reload).to be_suppressed
    expect(offer.reload).to be_cancelled
    expect(offer.cancel_reason).to include("mailing address")
    expect(entry.reload).to be_waiting
    expect(entry.delivery_failure).to include("mailing address")
    expect(ticket.reload.available_quantity).to eq(3)
  end

  it "reverts a suppressed alert and lets a later certified retry use the current address" do
    entry.notify!
    first = EmailService.send_waitlist_notification_async(entry)
    event.organization.update!(marketing_address_certified_at: nil)
    MessageDeliveryJob.perform_now(first.id)
    expect(entry.reload).to be_waiting
    expect(entry.delivery_failure).to include("mailing address")

    event.organization.update!(marketing_mailing_address: "456 New Road, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    entry.notify!
    second = EmailService.send_waitlist_notification_async(entry)
    MessageDeliveryJob.perform_now(second.id)
    expect(second.reload).to be_sent
    expect(second.outbound_payload.fetch("html")).to include("456 New Road")
    expect(entry.reload).to be_notified
  end

  it "hydrates a queued legacy alert from the certified address at send time" do
    event.organization.update!(marketing_address_certified_at: nil)
    entry.update!(status: :notified, notified_at: Time.current)
    delivery = EmailService.send_waitlist_notification_async(entry)
    expect(delivery.metadata["mailing_address"]).to eq("123 Marine Drive, Hagåtña, GU 96910")
    event.organization.update!(marketing_mailing_address: "789 Certified Lane, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    MessageDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload).to be_sent
    expect(delivery.outbound_payload.fetch("html")).to include("789 Certified Lane")
  end

  it "does not send after an event opt-out during payload preparation" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    allow(EmailService).to receive(:prepare_delivery_payload).and_wrap_original do |original, *args|
      payload = original.call(*args)
      WaitlistUnsubscribe.stop!(entry)
      payload
    end
    allow(EmailService).to receive(:send_delivery_payload)
    MessageDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload).to be_cancelled
    expect(EmailService).not_to have_received(:send_delivery_payload)
  end

  it "restores the prior provider uncertainty marker when a prepared alert becomes obsolete" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(provider: "simulated", provider_outcome_unknown: false)
    job = MessageDeliveryJob.new
    allow(job).to receive(:obsolete_waitlist?).and_return(false, true)
    allow(EmailService).to receive(:send_delivery_payload)

    job.perform(delivery.id)

    expect(delivery.reload).to have_attributes(status: "cancelled", provider_outcome_unknown: false)
    expect(EmailService).not_to have_received(:send_delivery_payload)
  end

  it "sweeps an old failed alert that still holds a notified entry" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :failed, last_error: "provider rejected", updated_at: 4.days.ago)
    SweepWaitlistDeliveriesJob.perform_now
    expect(entry.reload).to be_waiting
  end

  it "releases a suppressed offer even if an earlier provider result was uncertain" do
    ticket = create(:ticket_type, event: event, quantity_available: 3)
    offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ticket)
    delivery = MessageDelivery.find_by!(idempotency_key: "waitlist-offer/#{offer.id}")
    delivery.update!(status: :suppressed, provider_outcome_unknown: true, last_error: "buyer opted out")
    SweepWaitlistDeliveriesJob.perform_now
    expect(offer.reload).to be_cancelled
    expect(entry.reload).to be_waiting
    expect(ticket.reload.available_quantity).to eq(3)
  end

  it "sweeps a known failed offer and releases its inventory" do
    ticket = create(:ticket_type, event: event, quantity_available: 3)
    offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ticket)
    delivery = MessageDelivery.find_by!(idempotency_key: "waitlist-offer/#{offer.id}")
    delivery.update!(status: :failed, last_error: "provider rejected")
    SweepWaitlistDeliveriesJob.perform_now
    expect(offer.reload).to be_cancelled
    expect(entry.reload).to be_waiting
    expect(ticket.reload.available_quantity).to eq(3)
  end

  it "sweeps a failed alert even when provider acceptance is uncertain" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :failed, provider_outcome_unknown: true, last_error: "transport timed out")
    SweepWaitlistDeliveriesJob.perform_now
    expect(entry.reload).to be_waiting
    expect(entry.delivery_failure).to eq("transport timed out")
  end

  it "sweeps a known failed alert back to waiting" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :failed, last_error: "provider rejected")
    SweepWaitlistDeliveriesJob.perform_now
    expect(entry.reload).to be_waiting
    expect(entry.delivery_failure).to eq("provider rejected")
  end
end
