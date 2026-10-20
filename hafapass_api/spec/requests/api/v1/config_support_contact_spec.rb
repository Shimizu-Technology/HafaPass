# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public support contact configuration", type: :request do
  it "exposes the admin-managed support email and phone" do
    SiteSetting.instance.update!(platform_email: "help@example.test", platform_phone: "+1 671 555 0100")

    get "/api/v1/config"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("support_email" => "help@example.test", "support_phone" => "+1 671 555 0100")
  end

  it "reports no contact rather than a hardcoded fallback when nothing is configured" do
    SiteSetting.instance.update!(platform_email: " ", platform_phone: nil)

    get "/api/v1/config"

    expect(response.parsed_body).to include("support_email" => nil, "support_phone" => nil)
  end
end
