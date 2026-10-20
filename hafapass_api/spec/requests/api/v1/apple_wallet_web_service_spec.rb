require "rails_helper"

RSpec.describe "Apple Wallet PassKit web service", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:base) { "/api/v1/wallet/apple/v1" }
  let(:pass_type) { "pass.com.hafapass.ticket" }
  let(:device) { "a1b2c3d4e5f6" }
  let(:push_token) { "ab" * 32 }
  let(:ticket) { wallet_ticket }
  let!(:token) do
    configure_apple_wallet
    pass_json(Wallet::ApplePassGenerator.call(ticket))["authenticationToken"]
  end
  let(:wallet_pass) { WalletPass.apple.sole }
  let(:serial) { wallet_pass.serial_number }
  let(:auth) { { "Authorization" => "ApplePass #{token}" } }

  def register(headers: auth, body: { pushToken: push_token })
    post "#{base}/devices/#{device}/registrations/#{pass_type}/#{serial}", params: body, headers: headers, as: :json
  end

  it "registers a device once and reports an existing registration" do
    register
    expect(response).to have_http_status(:created)
    register
    expect(response).to have_http_status(:ok)
    expect(wallet_pass.apple_wallet_registrations.sole).to have_attributes(device_library_identifier: device, push_token: push_token)
  end

  it "rejects a missing, wrong or other-pass token" do
    register(headers: {})
    expect(response).to have_http_status(:unauthorized)
    register(headers: { "Authorization" => "ApplePass wrong-token-value-123" })
    expect(response).to have_http_status(:unauthorized)
    register(headers: { "Authorization" => "Bearer #{token}" })
    expect(response).to have_http_status(:unauthorized)
    expect(AppleWalletRegistration.count).to eq(0)
  end

  it "validates the push token, device identifier and pass type" do
    register(body: { pushToken: "not hex!" })
    expect(response).to have_http_status(:bad_request)
    post "#{base}/devices/#{device}/registrations/pass.com.other/#{serial}", params: { pushToken: push_token }, headers: auth, as: :json
    expect(response).to have_http_status(:not_found)
    get "#{base}/devices/#{device}/registrations/#{pass_type}", params: { passesUpdatedSince: "yesterday" }
    expect(response).to have_http_status(:bad_request)
  end

  it "keeps only the newest devices for one pass" do
    stub_const("Api::V1::AppleWalletWebServiceController::MAX_DEVICES_PER_PASS", 2)
    %w[device1 device2 device3].each_with_index do |id, index|
      travel_to(index.minutes.from_now) do
        post "#{base}/devices/#{id}/registrations/#{pass_type}/#{serial}", params: { pushToken: push_token }, headers: auth, as: :json
      end
    end
    expect(wallet_pass.apple_wallet_registrations.pluck(:device_library_identifier)).to contain_exactly("device2", "device3")
  end

  it "lists serials changed since the last tag, including changes that never queued a sync" do
    register
    get "#{base}/devices/#{device}/registrations/#{pass_type}"
    expect(response).to have_http_status(:ok)
    tag = response.parsed_body.fetch("lastUpdated")
    expect(response.parsed_body.fetch("serialNumbers")).to eq([serial])

    get "#{base}/devices/#{device}/registrations/#{pass_type}", params: { passesUpdatedSince: tag }
    expect(response).to have_http_status(:no_content)

    ticket.update_columns(status: Ticket.statuses[:cancelled])
    get "#{base}/devices/#{device}/registrations/#{pass_type}", params: { passesUpdatedSince: tag }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("serialNumbers")).to eq([serial])
    expect(response.parsed_body.fetch("lastUpdated").to_i).to be > tag.to_i
  end

  it "does not rewrite passes on a first poll and lists the newest changes first" do
    register
    older = WalletPass.create!(ticket: wallet_ticket, provider: "apple", serial_number: "ticket-older-v1",
      scan_credential_version: 1, content_digest: "a", content_updated_at: 2.days.ago.change(usec: 0))
    older.apple_wallet_registrations.create!(device_library_identifier: device, push_token: push_token)
    stub_const("Api::V1::AppleWalletWebServiceController::MAX_SERIALS_PER_DEVICE", 1)
    allow(Wallet::PassSync).to receive(:refresh_apple_content!).and_call_original

    get "#{base}/devices/#{device}/registrations/#{pass_type}"
    expect(response.parsed_body.fetch("serialNumbers")).to eq([serial])
    expect(Wallet::PassSync).not_to have_received(:refresh_apple_content!)
  end

  it "throttles a single device without blocking other devices behind the same venue address" do
    freeze_time do
      40.times { |index| get "#{base}/devices/venue-device-#{index}/registrations/#{pass_type}" }
      expect(response).to have_http_status(:no_content)
      30.times { get "#{base}/devices/#{device}/registrations/#{pass_type}" }
      expect(response).to have_http_status(:no_content)
      get "#{base}/devices/#{device}/registrations/#{pass_type}"
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  it "answers an unknown device with no content" do
    get "#{base}/devices/unknown-device/registrations/#{pass_type}"
    expect(response).to have_http_status(:no_content)
  end

  it "serves the latest pass, honours If-Modified-Since and voids it after a transfer" do
    get "#{base}/passes/#{pass_type}/#{serial}", headers: auth
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/vnd.apple.pkpass")
    expect(pass_json(response.body).dig("barcode", "message")).to eq(ticket.scan_credential)
    last_modified = response.headers["Last-Modified"]

    get "#{base}/passes/#{pass_type}/#{serial}", headers: auth.merge("If-Modified-Since" => last_modified)
    expect(response).to have_http_status(:not_modified)

    travel_to(2.seconds.from_now) do
      ticket.update!(holder_email: "next@example.com", attendee_name: "Next Holder",
        scan_credential_version: ticket.scan_credential_version + 1)
      get "#{base}/passes/#{pass_type}/#{serial}", headers: auth.merge("If-Modified-Since" => last_modified)
    end
    expect(response).to have_http_status(:ok)
    pass = pass_json(response.body)
    expect(pass["voided"]).to be(true)
    expect(pass).not_to include("barcode", "barcodes")
    expect(pass["authenticationToken"]).to eq(token)
  end

  it "requires the pass token to download a pass" do
    get "#{base}/passes/#{pass_type}/#{serial}"
    expect(response).to have_http_status(:unauthorized)
  end

  it "unregisters a device" do
    register
    delete "#{base}/devices/#{device}/registrations/#{pass_type}/#{serial}", headers: auth
    expect(response).to have_http_status(:ok)
    expect(AppleWalletRegistration.count).to eq(0)
  end

  it "accepts bounded device logs" do
    post "#{base}/log", params: { logs: ["Pass update failed\nwith detail"] * 30 }, as: :json
    expect(response).to have_http_status(:ok)
  end

  it "stays closed until Apple Wallet approval is active" do
    allow(PlatformCapabilities).to receive(:enabled?).with("apple_wallet").and_return(false)
    register
    expect(response).to have_http_status(:service_unavailable)
    get "#{base}/passes/#{pass_type}/#{serial}", headers: auth
    expect(response).to have_http_status(:service_unavailable)
    expect(AppleWalletRegistration.count).to eq(0)
  end
end
