require "rails_helper"

RSpec.describe Wallet::ApplePassGenerator do
  it "packages a signed pass with a manifest and the current scan credential" do
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=HafaPass Test")
    certificate.public_key = key.public_key
    certificate.not_before = Time.current
    certificate.not_after = 1.year.from_now
    certificate.sign(key, OpenSSL::Digest::SHA256.new)
    p12 = OpenSSL::PKCS12.create("secret", "HafaPass", key, certificate)
    icon = Tempfile.new(["wallet-icon", ".png"])
    icon.binmode
    icon.write("test-icon")
    icon.close
    stub_const("ENV", ENV.to_h.merge(
      "APPLE_PASS_TYPE_IDENTIFIER" => "pass.com.hafapass.ticket",
      "APPLE_TEAM_IDENTIFIER" => "TEAM123",
      "APPLE_PASS_CERTIFICATE_BASE64" => Base64.strict_encode64(p12.to_der),
      "APPLE_PASS_CERTIFICATE_PASSWORD" => "secret",
      "APPLE_WWDR_CERTIFICATE_BASE64" => Base64.strict_encode64(certificate.to_der),
      "APPLE_PASS_ICON_PATH" => icon.path
    ))
    event = create(:event, :published)
    type = create(:ticket_type, event: event)
    order = create(:order, event: event)
    item = create(:order_item, order: order, ticket_type: type)
    ticket = create(:ticket, order: order, event: event, ticket_type: type, order_item: item)

    archive = Zip::File.open_buffer(described_class.call(ticket))
    pass = JSON.parse(archive.read("pass.json"))

    expect(archive.map(&:name)).to include("manifest.json", "signature", "icon.png")
    expect(pass.dig("barcode", "message")).to eq(ticket.scan_credential)
  ensure
    icon&.unlink
  end
end
