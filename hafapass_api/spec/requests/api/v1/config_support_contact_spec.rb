# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public support contact configuration", type: :request do
  it "exposes the admin-managed support email and phone" do
    SiteSetting.instance.update!(platform_email: "help@example.test", platform_phone: "+1 671 555 0100")

    get "/api/v1/config"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("support_email" => "help@example.test", "support_phone" => "+1 671 555 0100")
  end

  it "publishes the company support inbox for the previous configured default" do
    SiteSetting.instance.update!(platform_email: "ShimizuTechnology@gmail.com")

    get "/api/v1/config"

    expect(response.parsed_body.fetch("support_email")).to eq("support@shimizu-technology.com")
  end

  it "exposes the default support email when nothing is configured" do
    SiteSetting.instance.update!(platform_email: " ", platform_phone: nil)

    get "/api/v1/config"

    expect(response.parsed_body).to include("support_email" => "support@shimizu-technology.com", "support_phone" => nil)
    policies = response.parsed_body.fetch("policies")
    expect(policies.fetch("privacy").fetch("sections").last.fetch("body"))
      .to include("contact us at support@shimizu-technology.com")
  end
end
