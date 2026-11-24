require "rails_helper"
require "timeout"
require "benchmark"

RSpec.describe "Campaign lock isolation", type: :job, email_rate_limit: true do
  self.use_transactional_tests = false

  after do
    ActiveRecord::Base.connection.execute("TRUNCATE audit_logs, audit_write_failures, users, organizations, events, email_rate_slots RESTART IDENTITY CASCADE")
  end

  %w[slot HTTP].each do |phase|
    it "B3/N1: lets same-organizer check-ins lock promptly during #{phase}" do
      event = create(:event, :published)
      organization = event.organization
      organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910", marketing_address_certified_at: Time.current)
      order = create(:order, event: event, marketing_opt_in: true)
      sender = create(:user)
      create(:organization_membership, organization: organization, user: sender, role: :marketer)
      campaign = create(:communication_campaign, event: event, status: :sending, sent_by_user: sender)
      message = create(:message_delivery, event: event, order: order, communication_campaign: campaign,
        requested_by: sender, template: "communication_campaign", recipient: order.buyer_email,
        metadata: { subject: campaign.subject, body: campaign.body, mailing_address: organization.marketing_mailing_address, organizer_name: organization.name })
      allow(EmailService).to receive(:configured?).and_return(true)
      allow(EmailService).to receive(:verify_transport_context!)
      allow(EmailService).to receive(:transport_context_digest).and_return("test")
      reached = Queue.new
      release = Queue.new
      pause = lambda do
        expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
        reached << true
        Timeout.timeout(5) { release.pop }
      end
      allow(EmailRateSlot).to receive(:sleep) { pause.call if phase == "slot" }
      allow(EmailService).to receive(:send_delivery_payload) do
        pause.call if phase == "HTTP"
        { id: "lock-probe" }
      end
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { MessageDeliveryJob.new.perform(message.id) }
      end
      Timeout.timeout(5) { reached.pop }
      elapsed = Benchmark.realtime do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '180ms'")
          # Same organizer lock used by Ticket#with_entry_lock at the door.
          Organization.lock("FOR NO KEY UPDATE").find(organization.id)
        end
      end
      backoff_elapsed = Benchmark.realtime { EmailRateSlot.backoff! }
      puts "B3 #{phase}: organizer=#{(elapsed * 1000).round(2)}ms; slot backoff=#{(backoff_elapsed * 1000).round(2)}ms"
      expect(elapsed).to be < 0.2
      expect(backoff_elapsed).to be < 0.2
      release << true
      Timeout.timeout(5) { worker.value }
      expect(message.reload).to have_attributes(status: "sent", attempts: 1)
      MessageDeliveryJob.new.perform(message.id)
      expect(EmailService).to have_received(:send_delivery_payload).once
    ensure
      release << true if release
      worker&.join(6)
      worker&.kill if worker&.alive?
    end
  end
end
