require "rails_helper"

RSpec.describe GtTranslationService, :webmock do
  let(:endpoint) { "https://runtime2.gtx.dev/v2/translate" }

  before { with_gt_credentials }

  it "posts one request per target locale and returns translations by key and locale" do
    stub_request(:post, endpoint).to_return do |request|
      body = JSON.parse(request.body)
      translated = body.fetch("requests").transform_values { |entry| { "translation" => "#{body['targetLocale']}:#{entry['source']}" } }
      { status: 200, body: translated.to_json, headers: { "Content-Type" => "application/json" } }
    end

    result = described_class.new.translate({ "title" => "Fiesta", "description" => "", "name" => "VIP" }, context: "Guam")

    expect(result.keys).to contain_exactly("title", "name")
    expect(result["title"]).to eq(AppLocale::TRANSLATION_TARGETS.index_with { |locale| "#{AppLocale.gt_code(locale)}:Fiesta" })
    expect(a_request(:post, endpoint).with(headers: { "x-gt-api-key" => "test-key", "x-gt-project-id" => "test-project" }) { |request|
      body = JSON.parse(request.body)
      body["sourceLocale"] == "en" && body.dig("requests", "title", "metadata", "context") == "Guam" &&
        !body["requests"].key?("description")
    }).to have_been_made.times(AppLocale::TRANSLATION_TARGETS.size)
    expect(a_request(:post, endpoint).with { |request| JSON.parse(request.body)["targetLocale"] == "fil" }).to have_been_made.once
  end

  it "skips keys the service did not translate" do
    stub_request(:post, endpoint).to_return(status: 200, body: { "title" => { "error" => "nope" } }.to_json)

    expect(described_class.new.translate({ "title" => "Fiesta" }, locales: %w[ko])).to eq({})
  end

  it "raises a TranslationError without echoing the response on HTTP, JSON and network failures" do
    stub_request(:post, endpoint).to_return(status: 500, body: "secret-ish body")
    expect { described_class.new.translate({ "title" => "x" }, locales: %w[ko]) }
      .to raise_error(described_class::TranslationError, "General Translation returned HTTP 500")

    stub_request(:post, endpoint).to_return(status: 200, body: "not json")
    expect { described_class.new.translate({ "title" => "x" }, locales: %w[ko]) }
      .to raise_error(described_class::TranslationError, /invalid JSON/)

    stub_request(:post, endpoint).to_timeout
    expect { described_class.new.translate({ "title" => "x" }, locales: %w[ko]) }
      .to raise_error(described_class::TranslationError, /request failed/)
  end

  it "reports exhausted credit and rate limits as unavailable" do
    stub_request(:post, endpoint).to_return(status: 402, body: "insufficient credit")
    expect { described_class.new.translate({ "title" => "x" }, locales: %w[ko]) }.to raise_error(described_class::Unavailable)

    stub_request(:post, endpoint).to_return(status: 429)
    expect { described_class.new.translate({ "title" => "x" }, locales: %w[ko]) }.to raise_error(described_class::Unavailable)

    stub_request(:post, endpoint).to_return(status: 400, body: { error: "Your account's credit balance is insufficient" }.to_json)
    expect { described_class.new.translate({ "title" => "x" }, locales: %w[ko]) }.to raise_error(described_class::Unavailable)
  end

  it "makes no request while the machine translation switch is off" do
    with_gt_credentials(machine_translation: false)
    expect(described_class).not_to be_enabled
    expect { described_class.new.translate({ "title" => "x" }) }.to raise_error(described_class::TranslationError, /not enabled/)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it "refuses to run without credentials" do
    stub_const("ENV", ENV.to_h.merge("GT_API_KEY" => ""))
    expect(described_class).not_to be_configured
    expect { described_class.new.translate({ "title" => "x" }) }.to raise_error(described_class::TranslationError)
  end
end
