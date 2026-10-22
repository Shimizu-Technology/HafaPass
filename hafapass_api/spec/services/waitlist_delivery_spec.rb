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
    delivery.update!(status: :failed, last_error: "Resend::Error::InvalidRequestError: recipient rejected")
    SweepWaitlistDeliveriesJob.perform_now
    expect(offer.reload).to be_cancelled
    expect(entry.reload).to be_waiting
    expect(ticket.reload.available_quantity).to eq(3)
  end

  it "keeps an uncertain offer reserved until the organizer explicitly retries its email" do
    ticket = create(:ticket_type, event: event, quantity_available: 3)
    offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ticket)
    delivery = MessageDelivery.find_by!(idempotency_key: "waitlist-offer/#{offer.id}")
    delivery.update!(status: :failed, provider_outcome_unknown: true, last_error: "timeout")

    SweepWaitlistDeliveriesJob.perform_now
    expect(offer.reload).to be_offered
    expect(entry.reload).to be_offered
    expect(entry.delivery_failure).to eq(described_class::UNCONFIRMED)
    expect(described_class.retry_unconfirmed_offer!(entry)).to be true
    expect(described_class.retry_unconfirmed_offer!(entry.reload)).to be false
    expect(MessageDelivery.where(template: "waitlist_offer").count).to eq(2)
    expect(offer.reload).to be_offered
  end

  it "keeps a generic known failure offer active until normal expiry" do
    ticket = create(:ticket_type, event: event, quantity_available: 3)
    offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ticket)
    delivery = MessageDelivery.find_by!(idempotency_key: "waitlist-offer/#{offer.id}")
    delivery.update!(status: :failed, provider_outcome_unknown: false, last_error: "Provider unavailable")

    described_class.reconcile_failure!(delivery)

    expect(offer.reload).to be_offered
    expect(entry.reload).to be_offered
    expect(entry.delivery_failure).to eq(described_class::UNCONFIRMED)
  end

  it "releases an offer when the provider rejects the recipient" do
    ticket = create(:ticket_type, event: event, quantity_available: 3)
    offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ticket)
    delivery = MessageDelivery.find_by!(idempotency_key: "waitlist-offer/#{offer.id}")
    delivery.update!(provider: "resend", provider_id: "rejected-offer-#{offer.id}", status: :sent)

    MessageProviderEventProcessor.call(provider_event_id: "failed-offer-#{offer.id}", event: {
      "type" => "email.failed", "created_at" => Time.current.iso8601,
      "data" => { "email_id" => delivery.provider_id, "bounce" => { "message" => "Mailbox does not exist" } }
    })
    SweepWaitlistDeliveriesJob.perform_now

    expect(offer.reload).to be_cancelled
    expect(entry.reload).to be_waiting
  end

  it "records a delivered receipt for a withdrawn offer and leaves the buyer waiting" do
    ticket = create(:ticket_type, event: event, quantity_available: 3)
    offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ticket)
    delivery = MessageDelivery.find_by!(idempotency_key: "waitlist-offer/#{offer.id}")
    offer.update!(status: :cancelled, token_version: offer.token_version + 1, cancel_reason: "Inventory withdrawn")
    entry.update!(status: :waiting, expires_at: nil)
    delivery.update!(status: :delivered)

    described_class.reconcile_success!(delivery)

    expect(delivery.reload.metadata["delivered_after_offer_withdrawal"]).to be(true)
    expect(entry.reload).to be_waiting
    expect(entry.delivery_failure).to include("withdrawn offer email")
  end

  it "keeps an uncertain alert notified and offers an explicit manual retry" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :failed, provider_outcome_unknown: true, last_error: "transport timed out")
    SweepWaitlistDeliveriesJob.perform_now
    expect(entry.reload).to be_notified
    expect(entry.delivery_failure).to eq(described_class::UNCONFIRMED)
    expect(delivery.reload.reconciled_at).to be_present
    expect(entry.retry_unconfirmed_notification!).to be true
    expect(entry.reload).to be_notified
    expect(entry.delivery_failure).to be_nil
    expect(MessageDelivery.where(template: "waitlist_notification").count).to eq(2)
  end

  it "sweeps a known failed alert back to waiting" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :failed, last_error: "provider rejected")
    SweepWaitlistDeliveriesJob.perform_now
    expect(entry.reload).to be_waiting
    expect(entry.delivery_failure).to eq("provider rejected")
  end

  it "lets a checkout claim win between loading and locking an offer" do
    ticket = create(:ticket_type, event: event, quantity_available: 3)
    offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ticket)
    delivery = MessageDelivery.find_by!(idempotency_key: "waitlist-offer/#{offer.id}")
    delivery.update!(status: :failed, last_error: "rejected")
    allow_any_instance_of(WaitlistOffer).to receive(:lock!).and_wrap_original do |original, *args|
      offer.update_columns(status: WaitlistOffer.statuses.fetch("claimed"), claimed_at: Time.current)
      original.call(*args)
    end

    described_class.reconcile_failure!(delivery)

    expect(offer.reload).to be_claimed
    expect(entry.reload).to be_offered
    expect(delivery.reload.reconciled_at).to be_present
    expect(entry.delivery_failure).to be_nil
  end

  it "uses the delivery status reloaded under its lock" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :failed, last_error: "stale failure")
    allow(delivery).to receive(:lock!).and_wrap_original do |original, *args|
      MessageDelivery.where(id: delivery.id).update_all(status: MessageDelivery.statuses.fetch("delivered"))
      original.call(*args)
    end

    described_class.reconcile_failure!(delivery)

    expect(entry.reload).to be_notified
    expect(entry.delivery_failure).to be_nil
    expect(delivery.reload.reconciled_at).to be_nil
  end

  it "does not create another alert when a delivered receipt arrives after a revert" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :failed, last_error: "provider rejected", provider_id: "late-#{delivery.id}")
    described_class.reconcile_failure!(delivery)
    expect(entry.reload).to be_waiting

    delivery.update!(status: :delivered)
    described_class.reconcile_success!(delivery)

    expect(entry.reload).to be_notified
    expect(entry.notify_and_queue!).to be false
    expect(MessageDelivery.where(template: "waitlist_notification").count).to eq(1)
  end

  it "caps each sweep at the oldest 500 failures and marks them once" do
    now = Time.current
    rows = 501.times.map do |index|
      { event_id: event.id, template: "waitlist_notification", recipient: "buyer#{index}@example.com",
        idempotency_key: "sweep-bound/#{SecureRandom.uuid}", provider: "simulated", channel: "email",
        status: MessageDelivery.statuses.fetch("failed"), metadata: { waitlist_entry_id: entry.id },
        created_at: now + index.seconds, updated_at: now }
    end
    MessageDelivery.insert_all!(rows)

    SweepWaitlistDeliveriesJob.perform_now
    expect(MessageDelivery.where(reconciled_at: nil, template: "waitlist_notification").count).to eq(1)
    expect(MessageDelivery.where(reconciled_at: nil, template: "waitlist_notification").pick(:created_at)).to be_within(1.second).of(now + 500.seconds)
    SweepWaitlistDeliveriesJob.perform_now
    expect(MessageDelivery.where(reconciled_at: nil, template: "waitlist_notification").count).to eq(0)
  end

  it "requeues a hard-bounced alert with a retryable reason" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :bounced, last_error: "Mailbox unavailable")

    SweepWaitlistDeliveriesJob.perform_now

    expect(entry.reload).to be_waiting
    expect(entry.delivery_failure).to include("Email bounced")
    expect(delivery.reload.reconciled_at).to be_present
  end

  it "records a complaint as an opt-out without requeuing the entry" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :complained)

    SweepWaitlistDeliveriesJob.perform_now

    expect(entry.reload).to be_notified
    expect(entry.delivery_failure).to include("opted out")
    expect(MarketingUnsubscribe.find_by!(organization: event.organization, email: entry.email).unsubscribed_at).to be_present
    expect(delivery.reload.reconciled_at).to be_present
  end

  it "keeps a transient bounce unconfirmed rather than releasing the alert" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    at = Time.current
    delivery.update!(status: :bounced, last_event_at: at)
    MessageProviderEvent.create!(message_delivery: delivery, provider: delivery.provider,
      provider_event_id: "transient-#{delivery.id}", provider_message_id: "transient-#{delivery.id}",
      event_type: "email.bounced", occurred_at: at, received_at: at,
      payload: { bounce: { type: "Transient" } })

    SweepWaitlistDeliveriesJob.perform_now

    expect(entry.reload).to be_notified
    expect(entry.delivery_failure).to eq(described_class::UNCONFIRMED)
  end
end
