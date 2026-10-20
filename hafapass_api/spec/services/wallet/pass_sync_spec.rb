require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_have_enqueued_job, :have_enqueued_job

RSpec.describe Wallet::PassSync do
  include ActiveJob::TestHelper

  describe "ticket state changes" do
    let(:ticket) { wallet_ticket }
    let!(:wallet_pass) do
      WalletPass.create!(ticket: ticket, provider: "apple", serial_number: "ticket-#{ticket.id}-v0",
        scan_credential_version: ticket.scan_credential_version)
    end

    it "queues a sync when the holder rotates the scan code" do
      expect { ticket.rotate_scan_credential! }.to have_enqueued_job(WalletPassSyncJob).with(wallet_pass.id)
    end

    it "queues a sync when a transfer is accepted" do
      recipient = create(:user, email: "recipient@example.com")
      ticket.event.update_columns(transfers_enabled: true)
      allow(EmailService).to receive(:send_ticket_transfer_async)
      allow(ClerkIdentity).to receive(:verified_email_addresses).and_return([recipient.email])
      transfer = TicketTransfers::Manager.create!(ticket: ticket, recipient_email: recipient.email)

      expect { TicketTransfers::Manager.accept!(token: TicketTransferCredential.issue(transfer), user: recipient) }
        .to have_enqueued_job(WalletPassSyncJob).with(wallet_pass.id)
    end

    it "queues a sync on cancellation, check-in, refunds, disputes and retained inventory" do
      expect { ticket.update!(status: :checked_in, checked_in_at: Time.current) }.to have_enqueued_job(WalletPassSyncJob)
      expect { ticket.order.update!(status: :refunded) }.to have_enqueued_job(WalletPassSyncJob)
      expect do
        Dispute.create!(order: ticket.order, provider: "stripe", provider_dispute_id: "dp_sync", currency: "usd",
          opened_at: Time.current, amount_cents: 100, status: :open)
      end.to have_enqueued_job(WalletPassSyncJob)
      refund = create(:refund, order: ticket.order, status: :pending, succeeded_at: nil)
      expect { refund.update!(status: :succeeded, succeeded_at: Time.current) }.to have_enqueued_job(WalletPassSyncJob)
      expect { ticket.event.update!(status: :cancelled) }.to have_enqueued_job(WalletPassFanoutJob).with(ticket.event_id)
    end

    it "fans an event change out from one job in batches instead of one job per pass in the request" do
      second = create(:ticket, order: ticket.order, event: ticket.event, ticket_type: ticket.ticket_type, order_item: ticket.order_item)
      other_pass = WalletPass.create!(ticket: second, provider: "google", serial_number: "issuer.hafapass_ticket_#{second.id}_v1",
        scan_credential_version: second.scan_credential_version)

      expect { ticket.event.update!(title: "Renamed event") }
        .to have_enqueued_job(WalletPassFanoutJob).exactly(:once).and(not_have_enqueued_job(WalletPassSyncJob))
      stub_const("WalletPassFanoutJob::BATCH_SIZE", 1)
      expect { WalletPassFanoutJob.perform_now(ticket.event_id) }.to have_enqueued_job(WalletPassSyncJob).exactly(:twice)
      expect(enqueued_jobs.filter_map { |job| job["arguments"].first if job["job_class"] == "WalletPassSyncJob" })
        .to include(wallet_pass.id, other_pass.id)
    end

    it "does not queue a fan-out for an event without saved passes" do
      expect { wallet_ticket.event.update!(title: "No passes") }.not_to have_enqueued_job(WalletPassFanoutJob)
    end

    it "does nothing for tickets without saved passes" do
      other = wallet_ticket
      expect { other.rotate_scan_credential! }.not_to have_enqueued_job(WalletPassSyncJob)
    end

    it "ignores changes a pass does not show" do
      expect { ticket.update!(holder_email: "same-holder@example.com") }.not_to have_enqueued_job(WalletPassSyncJob)
    end
  end

  describe "Apple" do
    let(:ticket) { wallet_ticket }
    let(:wallet_pass) do
      configure_apple_wallet
      Wallet::ApplePassGenerator.call(ticket)
      WalletPass.apple.sole.tap do |record|
        record.apple_wallet_registrations.create!(device_library_identifier: "device-1", push_token: "aa" * 32)
        record.apple_wallet_registrations.create!(device_library_identifier: "device-2", push_token: "bb" * 32)
      end
    end

    it "pushes every registered device once per content change" do
      apns = fake_apns
      described_class.call(wallet_pass)
      expect(apns.calls.sole).to eq(tokens: ["aa" * 32, "bb" * 32], topic: "pass.com.hafapass.ticket")

      expect(described_class.call(wallet_pass.reload)).to eq(:current)
      expect(apns.calls.length).to eq(1)

      ticket.rotate_scan_credential!
      expect(described_class.call(wallet_pass.reload)).to eq(:pushed)
      expect(apns.calls.length).to eq(2)
      expect(wallet_pass.reload.synced_digest).to eq(wallet_pass.content_digest)
    end

    it "drops registrations Apple reports as gone" do
      fake_apns("bb" * 32 => { status: 410, reason: "Unregistered" })
      described_class.call(wallet_pass)
      expect(wallet_pass.apple_wallet_registrations.pluck(:device_library_identifier)).to eq(["device-1"])
      expect(wallet_pass.reload).not_to be_sync_pending
    end

    it "retries throttled or failing pushes until delivered" do
      fake_apns("aa" * 32 => { status: 503, reason: "ServiceUnavailable" })
      expect { described_class.call(wallet_pass) }.to raise_error(described_class::RetryableError)
      expect(wallet_pass.reload).to be_sync_pending

      apns = fake_apns
      WalletPassSyncJob.perform_now(wallet_pass.id)
      expect(apns.calls.length).to eq(1)
      expect(wallet_pass.reload).not_to be_sync_pending
    end

    it "records a non-retryable push rejection on the pass" do
      fake_apns("aa" * 32 => { status: 400, reason: "BadTopic" })
      allow(Sentry).to receive(:capture_exception)
      WalletPassSyncJob.perform_now(wallet_pass.id)
      expect(wallet_pass.reload.last_error).to include("BadTopic")
      expect(Sentry).to have_received(:capture_exception)
    end

    it "is a no-op without Apple Wallet approval" do
      apns = fake_apns
      wallet_pass
      allow(PlatformCapabilities).to receive(:enabled?).with("apple_wallet").and_return(false)
      expect(described_class.call(wallet_pass)).to eq(:disabled)
      expect(apns.calls).to be_empty
    end
  end

  describe "Google", :webmock do
    let(:ticket) { wallet_ticket }
    let(:object_url) { %r{\Ahttps://walletobjects\.googleapis\.com/walletobjects/v1/eventTicketObject/3388000000000000000\.hafapass_ticket_\d+_v1\z} }
    let(:wallet_pass) do
      configure_google_wallet
      Wallet::GoogleSaveLink.call(ticket)
      WalletPass.google.sole
    end

    before do
      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(status: 200, body: { access_token: "ya29.synthetic", expires_in: 3600 }.to_json,
          headers: { "Content-Type" => "application/json" })
    end

    it "replaces the saved object without a barcode and deactivates it after rotation" do
      update = stub_request(:put, object_url).with(headers: { "Authorization" => "Bearer ya29.synthetic" })
        .to_return(status: 200, body: "{}")
      wallet_pass
      ticket.rotate_scan_credential!

      expect(described_class.call(wallet_pass.reload)).to eq(:updated)
      expect(update).to have_been_requested.once
      body = nil
      expect(a_request(:put, object_url).with { |request| body = JSON.parse(request.body) }).to have_been_made
      expect(body).to include("state" => "INACTIVE")
      expect(body).not_to have_key("barcode")

      expect(described_class.call(wallet_pass.reload)).to eq(:current)
      expect(update).to have_been_requested.once
    end

    it "marks a past event's pass as expired" do
      stub_request(:put, object_url).to_return(status: 200, body: "{}")
      wallet_pass
      ticket.event.update_columns(starts_at: 2.days.ago, ends_at: 1.day.ago)
      described_class.call(wallet_pass)
      expect(a_request(:put, object_url).with { |request| JSON.parse(request.body)["state"] == "EXPIRED" }).to have_been_made
    end

    it "creates an unsaved invalid object as inactive so an old save link cannot revive it" do
      stub_request(:put, object_url).to_return(status: 404, body: "{}")
      class_insert = stub_request(:post, "https://walletobjects.googleapis.com/walletobjects/v1/eventTicketClass").to_return(status: 409)
      object_insert = stub_request(:post, "https://walletobjects.googleapis.com/walletobjects/v1/eventTicketObject")
        .with { |request| JSON.parse(request.body)["state"] == "INACTIVE" && !JSON.parse(request.body).key?("barcode") }
        .to_return(status: 200, body: "{}")
      wallet_pass
      ticket.update!(status: :cancelled, cancelled_at: Time.current)

      described_class.call(wallet_pass.reload)
      expect(class_insert).to have_been_requested
      expect(object_insert).to have_been_requested
      expect(wallet_pass.reload).not_to be_sync_pending
    end

    it "retries Google throttling and then succeeds" do
      stub_request(:put, object_url).to_return({ status: 429 }, { status: 200, body: "{}" })
      wallet_pass
      ticket.rotate_scan_credential!

      expect { described_class.call(wallet_pass.reload) }.to raise_error(Wallet::GoogleWalletClient::RetryableError)
      expect(wallet_pass.reload).to be_sync_pending
      expect(described_class.call(wallet_pass.reload)).to eq(:updated)
    end

    it "is a no-op without Google Wallet approval and makes no requests" do
      wallet_pass
      allow(PlatformCapabilities).to receive(:enabled?).with("google_wallet").and_return(false)
      expect(described_class.call(wallet_pass)).to eq(:disabled)
      expect(a_request(:any, /googleapis/)).not_to have_been_made
    end
  end
end
