# frozen_string_literal: true

module WalletHelpers
  FakeApns = Struct.new(:responses, :calls) do
    def post_all(tokens, topic:)
      calls << { tokens: tokens, topic: topic }
      tokens.index_with { |token| Wallet::ApplePushNotifier::Result.new(**responses.fetch(token, { status: 200 })) }
    end
  end

  def self_signed_certificate(common_name = "HafaPass Test")
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=#{common_name}")
    certificate.public_key = key.public_key
    certificate.not_before = 1.minute.ago
    certificate.not_after = 1.year.from_now
    certificate.sign(key, OpenSSL::Digest::SHA256.new)
    [key, certificate]
  end

  def configure_apple_wallet(enabled: true, public_api_url: "https://api.hafapass.test")
    key, certificate = self_signed_certificate
    p12 = OpenSSL::PKCS12.create("secret", "HafaPass", key, certificate)
    icon = Tempfile.new(["wallet-icon", ".png"])
    icon.binmode
    icon.write("test-icon")
    icon.close
    @wallet_icons = [*@wallet_icons, icon]
    stub_const("ENV", ENV.to_h.merge(
      "APPLE_PASS_TYPE_IDENTIFIER" => "pass.com.hafapass.ticket",
      "APPLE_TEAM_IDENTIFIER" => "TEAM123",
      "APPLE_PASS_CERTIFICATE_BASE64" => Base64.strict_encode64(p12.to_der),
      "APPLE_PASS_CERTIFICATE_PASSWORD" => "secret",
      "APPLE_WWDR_CERTIFICATE_BASE64" => Base64.strict_encode64(certificate.to_der),
      "APPLE_PASS_ICON_PATH" => icon.path,
      "PUBLIC_API_URL" => public_api_url
    ))
    allow(PlatformCapabilities).to receive(:enabled?).and_call_original
    allow(PlatformCapabilities).to receive(:enabled?).with("apple_wallet").and_return(enabled)
  end

  def configure_google_wallet(enabled: true)
    key = OpenSSL::PKey::RSA.new(2048)
    stub_const("ENV", ENV.to_h.merge(
      "GOOGLE_WALLET_ISSUER_ID" => "3388000000000000000",
      "GOOGLE_WALLET_SERVICE_ACCOUNT_EMAIL" => "wallet@example.iam.gserviceaccount.com",
      "GOOGLE_WALLET_PRIVATE_KEY" => key.to_pem,
      "GOOGLE_WALLET_CLASS_REVIEW_STATUS" => "APPROVED",
      "FRONTEND_URL" => "https://hafapass.com"
    ))
    Wallet::GoogleWalletClient.reset_access_token!
    allow(PlatformCapabilities).to receive(:enabled?).and_call_original
    allow(PlatformCapabilities).to receive(:enabled?).with("google_wallet").and_return(enabled)
    key
  end

  def fake_apns(responses = {})
    FakeApns.new(responses, []).tap { |fake| Wallet::ApplePushNotifier.transport = fake }
  end

  def wallet_ticket(starts_at: 3.days.from_now, **attributes)
    event = create(:event, :published, starts_at: starts_at)
    type = create(:ticket_type, event: event)
    order = create(:order, event: event, **attributes)
    create(:ticket, order: order, event: event, ticket_type: type, order_item: create(:order_item, order: order, ticket_type: type))
  end

  def pass_json(pkpass)
    JSON.parse(Zip::File.open_buffer(pkpass).read("pass.json"))
  end
end

RSpec.configure do |config|
  config.include WalletHelpers
  config.after do
    Wallet::ApplePushNotifier.transport = nil
    @wallet_icons&.each(&:unlink)
  end
end
