require "rails_helper"
require "timeout"

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
    AuditLog.where(organization_id: @test_organization_id).delete_all
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

  def signal(queue)
    Timeout.timeout(3) { queue.pop }
  end

  it "finishes unsubscribe racing delivery reconciliation without lock inversion" do
    ticket = create(:ticket_type, event: event, quantity_available: 3)
    offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ticket)
    delivery = MessageDelivery.find_by!(idempotency_key: "waitlist-offer/#{offer.id}")
    delivery.update!(status: :failed, last_error: "Resend::Error::InvalidRequestError: rejected")
    ready = Queue.new
    release = Queue.new
    attempting = Queue.new
    acquired = Queue.new
    allow_any_instance_of(Organization).to receive(:lock!).and_wrap_original do |method, *arguments|
      attempting << true if Thread.current[:waitlist_reconcile]
      method.call(*arguments)
    end

    unsubscribe = worker do
      WaitlistLocks.with(entry: WaitlistEntry.find(entry.id), offer: WaitlistOffer.find(offer.id)) do
        ready << true
        release.pop
        WaitlistUnsubscribe.stop!(WaitlistEntry.find(entry.id))
        MessageDelivery.find(delivery.id).lock!
      end
    end
    signal(ready)
    reconcile = worker do
      Thread.current[:waitlist_reconcile] = true
      WaitlistLocks.with(entry: WaitlistEntry.find(entry.id), delivery: MessageDelivery.find(delivery.id)) do
        acquired << true
        WaitlistDelivery.reconcile_failure!(MessageDelivery.find(delivery.id))
      end
    end
    signal(attempting)
    release << true
    signal(acquired)
    finish(unsubscribe, reconcile)
    expect(entry.reload).to be_cancelled
  end

  def hard_bounced_alert
    entry.notify!
    delivery = EmailService.send_waitlist_notification_async(entry)
    delivery.update!(status: :sent, provider: "resend",
      provider_id: "late-receipt-#{delivery.id}")
    MessageProviderEventProcessor.call(provider_event_id: "bounce-#{delivery.id}", event: {
      "type" => "email.bounced", "created_at" => Time.current.iso8601,
      "data" => { "email_id" => delivery.provider_id,
        "bounce" => { "type" => "Permanent", "message" => "Mailbox does not exist" } }
    })
    expect(entry.reload).to be_waiting
    delivery
  end

  def late_delivery(delivery)
    MessageProviderEventProcessor.call(provider_event_id: "delivered-#{delivery.id}", event: {
      "type" => "email.delivered", "created_at" => 1.minute.from_now.iso8601,
      "data" => { "email_id" => delivery.provider_id }
    })
  end

  [:receipt_first, :new_round_first].each do |order|
    it "keeps a hard bounce and suppresses round two when #{order.to_s.tr('_', ' ')}" do
      delivery = hard_bounced_alert
      ready = Queue.new
      release = Queue.new
      attempting = Queue.new
      acquired = Queue.new
      allow_any_instance_of(Organization).to receive(:lock!).and_wrap_original do |method, *arguments|
        attempting << true if Thread.current[:waitlist_second]
        method.call(*arguments)
      end
      first = worker do
        WaitlistLocks.with(entry: WaitlistEntry.find(entry.id), delivery: MessageDelivery.find(delivery.id)) do
          ready << true
          release.pop
          order == :receipt_first ? late_delivery(delivery) : WaitlistEntry.find(entry.id).notify_and_queue!
        end
      end
      signal(ready)
      second = worker do
        Thread.current[:waitlist_second] = true
        WaitlistLocks.with(entry: WaitlistEntry.find(entry.id), delivery: MessageDelivery.find(delivery.id)) do
          acquired << true
          order == :receipt_first ? WaitlistEntry.find(entry.id).notify_and_queue! : late_delivery(delivery)
        end
      end
      signal(attempting)
      release << true
      signal(acquired)
      finish(first, second)

      round_two = MessageDelivery.where(template: "waitlist_notification", recipient: entry.email)
        .where.not(id: delivery.id).sole
      expect(delivery.reload).to be_bounced
      expect(delivery.metadata["provider_address_invalid"]).to be(true)
      expect(round_two.suppressed_recipient?).to be(true)
      allow(EmailService).to receive(:send_delivery_payload)
      MessageDeliveryJob.perform_now(round_two.id)
      expect(round_two.reload).to be_suppressed
      expect(EmailService).not_to have_received(:send_delivery_payload)
      expect(entry.reload.delivery_failure.downcase).to include("bounc")
    end
  end
end
