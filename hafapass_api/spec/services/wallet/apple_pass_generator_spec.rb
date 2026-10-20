require "rails_helper"

RSpec.describe Wallet::ApplePassGenerator do
  it "does not sign a configured pass before provider evidence is approved" do
    allow(described_class).to receive(:configured?).and_return(true)
    allow(PlatformCapabilities).to receive(:enabled?).with("apple_wallet").and_return(false)

    expect { described_class.call(instance_double(Ticket)) }
      .to raise_error(described_class::ConfigurationError, /disabled pending provider approval/)
  end

  it "packages a signed pass with a manifest and the current scan credential" do
    configure_apple_wallet
    ticket = wallet_ticket

    archive = Zip::File.open_buffer(described_class.call(ticket))
    pass = JSON.parse(archive.read("pass.json"))

    expect(archive.map(&:name)).to include("manifest.json", "signature", "icon.png")
    expect(pass.dig("barcode", "message")).to eq(ticket.scan_credential)
    expect(pass["voided"]).to be(false)
    expect(pass.dig("eventTicket", "headerFields", 0, "value")).to eq("Valid")
  end

  it "registers the pass for updates with a per-copy token that is stored only as a digest" do
    configure_apple_wallet
    ticket = wallet_ticket

    pass = pass_json(described_class.call(ticket))
    wallet_pass = WalletPass.find_by!(provider: "apple", serial_number: pass["serialNumber"])

    expect(pass["webServiceURL"]).to eq("https://api.hafapass.test/api/v1/wallet/apple")
    expect(pass["authenticationToken"].length).to be >= 16
    expect(wallet_pass.authentication_token_digests).to eq([WalletPass.digest_token(pass["authenticationToken"])])
    expect(wallet_pass.authentication_token_digests).not_to include(pass["authenticationToken"])
    expect(wallet_pass).to have_attributes(ticket: ticket, scan_credential_version: ticket.scan_credential_version)
    expect(wallet_pass.content_updated_at).to be_present
  end

  it "keeps earlier copies authenticated when the holder downloads the pass again" do
    configure_apple_wallet
    ticket = wallet_ticket

    first = pass_json(described_class.call(ticket))["authenticationToken"]
    second = pass_json(described_class.call(ticket))["authenticationToken"]
    wallet_pass = WalletPass.apple.sole

    expect(first).not_to eq(second)
    expect(wallet_pass.authenticates?(first)).to be(true)
    expect(wallet_pass.authenticates?(second)).to be(true)
    expect(wallet_pass.authenticates?("not-a-token")).to be(false)
  end

  it "omits the update service without an HTTPS public API origin" do
    configure_apple_wallet(public_api_url: "http://localhost:3000")

    pass = pass_json(described_class.call(wallet_ticket))

    expect(pass).not_to include("webServiceURL", "authenticationToken")
  end

  it "voids the latest pass and removes its barcode once the scan credential rotates" do
    configure_apple_wallet
    ticket = wallet_ticket
    token = pass_json(described_class.call(ticket))["authenticationToken"]
    wallet_pass = WalletPass.apple.sole
    ticket.rotate_scan_credential!

    pass = pass_json(described_class.latest(wallet_pass.reload, authentication_token: token))

    expect(pass["voided"]).to be(true)
    expect(pass).not_to include("barcode", "barcodes")
    expect(pass.dig("eventTicket", "headerFields", 0, "value")).to start_with("Replaced")
    expect(pass["authenticationToken"]).to eq(token)
  end

  it "pauses without voiding while a dispute is open, then restores the barcode" do
    configure_apple_wallet
    ticket = wallet_ticket
    described_class.call(ticket)
    wallet_pass = WalletPass.apple.sole
    dispute = Dispute.create!(order: ticket.order, provider: "stripe", provider_dispute_id: "dp_wallet", currency: "usd",
      opened_at: Time.current, amount_cents: 100, status: :open)

    paused = pass_json(described_class.latest(wallet_pass, authentication_token: nil))
    expect(paused["voided"]).to be(false)
    expect(paused).not_to include("barcode")
    expect(paused.dig("eventTicket", "headerFields", 0, "value")).to include("dispute")

    dispute.update!(status: :won)
    restored = pass_json(described_class.latest(wallet_pass, authentication_token: nil))
    expect(restored.dig("barcode", "message")).to eq(ticket.reload.scan_credential)
  end
end
