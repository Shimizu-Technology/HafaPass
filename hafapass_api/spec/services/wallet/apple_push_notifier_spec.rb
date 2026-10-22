require "rails_helper"
require "socket"
require "async/http/server"
require "async/http/endpoint"
require "async/http/protocol/http2"
require "protocol/http/response"

RSpec.describe Wallet::ApplePushNotifier do
  # A local HTTP/2 TLS server stands in for APNs, so the real transport is
  # exercised without contacting Apple.
  it "posts an empty payload per device over HTTP/2 with the pass topic and client certificate" do
    configure_apple_wallet
    server_key, server_certificate = local_certificate
    client_credentials = Wallet::ApplePassCertificate.load
    port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    presented = []
    received = []
    server_context = OpenSSL::SSL::SSLContext.new.tap do |context|
      context.cert = server_certificate
      context.key = server_key
      context.alpn_protocols = ["h2"]
      context.alpn_select_cb = ->(_protocols) { "h2" }
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.verify_callback = ->(_ok, store) { presented << store.current_cert.to_der; true }
    end
    client_context = OpenSSL::SSL::SSLContext.new.tap do |context|
      context.alpn_protocols = ["h2"]
      context.cert_store = OpenSSL::X509::Store.new.tap { |store| store.add_cert(server_certificate) }
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.cert = client_credentials.certificate
      context.key = client_credentials.key
    end
    endpoint = Async::HTTP::Endpoint.parse("https://localhost:#{port}", ssl_context: server_context,
      protocol: Async::HTTP::Protocol::HTTP2)
    server = Async::HTTP::Server.for(endpoint, protocol: Async::HTTP::Protocol::HTTP2) do |request|
      received << { path: request.path, topic: request.headers["apns-topic"], body: request.read, version: request.version }
      gone = request.path.end_with?("bb" * 32)
      Protocol::HTTP::Response[gone ? 410 : 200, {}, [gone ? '{"reason":"Unregistered"}' : ""]]
    end
    transport = described_class::AsyncTransport.new(host: "https://localhost:#{port}", ssl_context: client_context)

    @server_thread = Thread.new do
      # The stand-in is killed after the example; keep its shutdown quiet.
      Console.logger = Console::Logger.new(Console::Output::Null.new)
      Sync { server.run }
    end
    wait_for_port(port)
    results = transport.post_all(["aa" * 32, "bb" * 32], topic: "pass.com.hafapass.ticket")

    expect(received.map { |item| item[:path] }).to eq(["/3/device/#{'aa' * 32}", "/3/device/#{'bb' * 32}"])
    expect(received).to all(include(topic: ["pass.com.hafapass.ticket"], body: "{}", version: "HTTP/2"))
    expect(presented).to include(client_credentials.certificate.to_der)
    expect(results["aa" * 32]).to be_delivered
    expect(results["bb" * 32]).to have_attributes(status: 410, reason: "Unregistered")
    expect(results["bb" * 32]).to be_gone
  end

  it "reports connection failures as retryable" do
    configure_apple_wallet
    port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    transport = described_class::AsyncTransport.new(host: "https://localhost:#{port}")

    expect { transport.post_all(["aa" * 32], topic: "pass.com.hafapass.ticket") }
      .to raise_error(described_class::DeliveryError)
  end

  after { @server_thread&.kill&.join(5) }

  def wait_for_port(port)
    50.times do
      TCPSocket.new("127.0.0.1", port).close
      return
    rescue Errno::ECONNREFUSED
      sleep 0.05
    end
    raise "local APNs stand-in did not start"
  end

  def local_certificate
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 2
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
    certificate.public_key = key.public_key
    certificate.not_before = 1.minute.ago
    certificate.not_after = 1.hour.from_now
    extensions = OpenSSL::X509::ExtensionFactory.new(certificate, certificate)
    certificate.add_extension(extensions.create_extension("subjectAltName", "DNS:localhost", false))
    certificate.sign(key, OpenSSL::Digest::SHA256.new)
    [key, certificate]
  end
end
