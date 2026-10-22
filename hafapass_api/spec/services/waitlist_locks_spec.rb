require "rails_helper"

RSpec.describe WaitlistLocks do
  # The two workers need separate PostgreSQL connections and committed fixtures.
  self.use_transactional_tests = false

  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let(:entry) { create(:waitlist_entry, event: event) }

  before do
    @test_event_id = event.id
    @test_profile_id = event.organizer_profile_id
    @test_user_id = event.organizer_profile.user_id
    @test_organization_id = event.organization_id
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
  end

  after do
    next unless defined?(@test_event_id) && @test_event_id

    deliveries = MessageDelivery.where(event_id: @test_event_id)
    MessageProviderEvent.where(message_delivery_id: deliveries.select(:id)).delete_all
    deliveries.delete_all
    WaitlistOffer.where(event_id: @test_event_id).delete_all
    WaitlistEntry.where(event_id: @test_event_id).delete_all
    TicketType.where(event_id: @test_event_id).delete_all
    Event.where(id: @test_event_id).delete_all
    OrganizationMembership.where(organization_id: @test_organization_id).delete_all
    OrganizerProfile.where(id: @test_profile_id).delete_all
    User.where(id: @test_user_id).delete_all
    Organization.where(id: @test_organization_id).delete_all
  end

  def worker(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '1s'")
          block.call
        end
      end
    end
  end

  def finish(*threads)
    threads.each do |thread|
      expect(thread.join(3)).not_to be_nil
      thread.value
    end
  end

  it "finishes unsubscribe racing delivery reconciliation without lock inversion" do
    ticket = create(:ticket_type, event: event, quantity_available: 3)
    offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ticket)
    delivery = MessageDelivery.find_by!(idempotency_key: "waitlist-offer/#{offer.id}")
    delivery.update!(status: :failed, last_error: "Resend::Error::InvalidRequestError: rejected")
    ready = Queue.new
    release = Queue.new

    unsubscribe = worker do
      WaitlistLocks.with(entry: WaitlistEntry.find(entry.id), offer: WaitlistOffer.find(offer.id)) do
        ready << true
        release.pop
        WaitlistUnsubscribe.stop!(WaitlistEntry.find(entry.id))
        MessageDelivery.find(delivery.id).lock!
      end
    end
    ready.pop
    reconcile = worker { WaitlistDelivery.reconcile_failure!(MessageDelivery.find(delivery.id)) }
    sleep 0.05
    release << true
    finish(unsubscribe, reconcile)
    expect(entry.reload).to be_cancelled
  end

  it "serializes a late delivered receipt and the decision to start another alert round" do
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :failed, last_error: "recipient rejected", provider: "resend",
      provider_id: "late-receipt-#{delivery.id}")
    WaitlistDelivery.reconcile_failure!(delivery)
    expect(entry.reload).to be_waiting
    ready = Queue.new
    release = Queue.new

    receipt = worker do
      WaitlistLocks.with(entry: WaitlistEntry.find(entry.id), delivery: MessageDelivery.find(delivery.id)) do
        ready << true
        release.pop
        MessageProviderEventProcessor.call(provider_event_id: "delivered-#{delivery.id}", event: {
          "type" => "email.delivered", "created_at" => Time.current.iso8601,
          "data" => { "email_id" => "late-receipt-#{delivery.id}" }
        })
      end
    end
    ready.pop
    notify = worker { WaitlistEntry.find(entry.id).notify_and_queue! }
    sleep 0.05
    release << true
    finish(receipt, notify)

    expect(notify.value).to be(false)
    expect(entry.reload).to be_notified
    expect(MessageDelivery.where(template: "waitlist_notification", recipient: entry.email).count).to eq(1)
  end
end
