require "rails_helper"
require "stringio"

RSpec.describe "Backend credential observability privacy" do
  let(:credential) { SignedCredential.issue(namespace: "ticket_display", payload: { ticket_id: 999_999, version: 1 }) }
  let(:query_secret) { "synthetic-private-query-value" }
  let(:url) { "https://app.example.test/api/v1/tickets/#{credential}/download?campaign=#{query_secret}#fragment-private" }

  def env_for(url, method: "GET")
    Rack::MockRequest.env_for(url, method: method,
      "HTTP_X_REQUEST_ID" => "privacy-request-123",
      "HTTP_REFERER" => url,
      "action_dispatch.parameter_filter" => Rails.application.config.filter_parameters)
  end

  def sentry_error
    event = Sentry::ErrorEvent.new(configuration: Sentry.configuration, message: "Request failed: #{url}")
    event.rack_env = env_for(url)
    event.request.query_string = "campaign=#{query_secret}"
    event.request.data = { "credential" => credential, "nested" => { "email" => "synthetic@example.test" } }
    event.request.env = { "PATH_INFO" => "/api/v1/check_in/#{credential}", "QUERY_STRING" => query_secret }
    event.tags = { request_id: "privacy-request-123", path: url, credential: credential }
    event.extra = { "http" => { "url" => url, "authorization" => "Bearer #{credential}" } }
    event.transaction = url
    event.add_exception_interface(StandardError.new("Failed to fetch #{url}"), mechanism: Sentry::Mechanism.new)
    event.breadcrumbs = Sentry::BreadcrumbBuffer.new
    event.breadcrumbs.record(Sentry::Breadcrumb.new(message: "GET #{url}", data: { url: url, token: credential, qr_code: credential }))
    event
  end

  it "demonstrates that Rails parameter filtering alone retains bearer path segments" do
    request = ActionDispatch::Request.new(env_for(url))
    rails_view = ActionDispatch::Http::FilterParameters.instance_method(:filtered_path).bind(request).call
    expect(rails_view).to include(credential, query_secret)
    expect(request.filtered_path).not_to include(credential, query_secret)
  end

  it "sanitizes Rails' logged request views while leaving routing and authentication input intact" do
    %w[tickets check_in].each do |route|
      request = ActionDispatch::Request.new(env_for("/api/v1/#{route}/#{credential}?campaign=#{query_secret}"))
      request.path_parameters = { "controller" => "api/v1/tickets", "action" => "show", "credential" => credential }
      started = Rails::Rack::Logger.new(->(_env) { [200, {}, []] }).send(:started_request_message, request)

      expect(started).to include("Started GET", "/api/v1/#{route}/[FILTERED]")
      expect(started).not_to include(credential, query_secret, "?campaign")
      expect(request.filtered_parameters["credential"]).to eq("[FILTERED]")
      expect(request.filtered_parameters["campaign"]).to eq("[FILTERED]")
      expect(request.path).to include(credential)
      expect(request.fullpath).to include(credential, query_secret)
      expect(request.params["credential"]).to eq(credential)
      expect(request.params["campaign"]).to eq(query_secret)
    end
  end

  it "keeps method/controller/action/status/request-id/timing in real Lograge output" do
    original_hook = Lograge.class_variable_get(:@@before_format)
    original_options = Lograge.class_variable_get(:@@custom_options)
    Lograge.before_format = Rails.application.config.lograge.before_format
    Lograge.custom_options = Rails.application.config.lograge.custom_options
    output = StringIO.new
    subscriber = Lograge::LogSubscribers::ActionController.new
    allow(subscriber).to receive(:logger).and_return(ActiveSupport::Logger.new(output))
    allow(Lograge).to receive(:formatter).and_return(Rails.application.config.lograge.formatter)
    payload = { method: "GET", path: url, format: :json, controller: "Api::V1::TicketsController",
      action: "download", status: 404, request_id: "privacy-request-123", db_runtime: 2.0 }
    event = ActiveSupport::Notifications::Event.new("process_action.action_controller", 1.0, 1.025, "privacy", payload)
    subscriber.process_action(event)

    record = JSON.parse(output.string)
    expect(record).to include("method" => "GET", "controller" => "Api::V1::TicketsController",
      "action" => "download", "status" => 404, "request_id" => "privacy-request-123", "duration" => 25.0)
    expect(record["path"]).to include("/tickets/[FILTERED]/download")
    expect(output.string).not_to include(credential, query_secret, "fragment-private")
  ensure
    Lograge.before_format = original_hook
    Lograge.custom_options = original_options
  end

  it "scrubs URL text in routing errors/redirects without breaking TaggedLogging" do
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    TelemetryPrivacy.install_logger!(logger)
    logger.tagged("privacy-request-123", url) { logger.error("No route matches [GET] #{url}") }
    logger.info({ url: url, credential: credential, method: "GET" })

    expect(output.string).to include("privacy-request-123", "No route matches [GET]", "[FILTERED]", "GET")
    expect(output.string).not_to include(credential, query_secret, "fragment-private")
    expect(logger.formatter).to respond_to(:push_tags, :pop_tags)
  end

  it "scrubs Sentry error request URLs, headers, environment, tags, breadcrumbs and exception URLs" do
    source_event = sentry_error
    # The installed SDK retains a bearer URL path even with default PII off.
    expect(source_event.request.url).to include(credential)
    event = Sentry.configuration.before_send.call(source_event, {})
    serialized = JSON.generate(event.to_hash)

    expect(serialized).not_to include(credential, query_secret, "synthetic@example.test", "fragment-private")
    expect(event.request.url).to eq("https://app.example.test/api/v1/tickets/[FILTERED]/download")
    expect(event.tags[:request_id]).to eq("privacy-request-123")
    expect(event.request.method).to eq("GET")
    expect(event.request.query_string).to be_nil
    expect(event.exception.values.first.type).to eq("StandardError")
  end

  it "sanitizes breadcrumbs before they are retained in Sentry scope" do
    crumb = Sentry::Breadcrumb.new(category: "http", message: "GET #{url}",
      data: { url: url, headers: { Authorization: "Bearer #{credential}" }, method: "GET", status_code: 404 })
    sanitized = Sentry.configuration.before_breadcrumb.call(crumb, {})
    serialized = JSON.generate(sanitized.to_hash)

    expect(serialized).not_to include(credential, query_secret, "fragment-private")
    expect(sanitized.data).to include(method: "GET", status_code: 404)
    expect(sanitized.category).to eq("http")
  end

  it "scrubs Sentry transaction/span paths through the transaction hook as well" do
    transaction = Sentry::Transaction.new(hub: Sentry.get_current_hub, name: url, op: "http.server")
    span = transaction.start_child(op: "http.client", description: "POST #{url}")
    span.set_data(:path, url)
    span.set_data("http.query", query_secret)
    span.set_data(:credential, credential)
    span.finish
    event = Sentry::TransactionEvent.new(transaction: transaction, configuration: Sentry.configuration)
    event.rack_env = env_for(url)
    sanitized = Sentry.configuration.before_send_transaction.call(event, {})
    serialized = JSON.generate(sanitized.to_hash)

    expect(serialized).not_to include(credential, query_secret, "fragment-private")
    expect(sanitized.spans.first).to include(op: "http.client")
    expect(sanitized.spans.first[:data][:path]).to include("/tickets/[FILTERED]/download")
    expect(sanitized.type).to eq("transaction")
  end

  it "handles encoded credentials, ticket subroutes and non-secret paths" do
    %w[download wallet/apple wallet/google].each do |suffix|
      expect(TelemetryPrivacy.path("/api/v1/tickets/#{ERB::Util.url_encode(credential)}/#{suffix}?q=#{query_secret}"))
        .to eq("/api/v1/tickets/[FILTERED]/#{suffix}")
    end
    expect(TelemetryPrivacy.path("/api/v1/health?anything=#{query_secret}")).to eq("/api/v1/health")
    expect(TelemetryPrivacy.path("/api/v1/organization_invitations/accept")).to eq("/api/v1/organization_invitations/accept")
  end
end
