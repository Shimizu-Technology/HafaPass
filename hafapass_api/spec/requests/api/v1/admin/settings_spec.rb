require "rails_helper"

RSpec.describe "Admin settings", type: :request do
  let(:admin) { create(:user, :admin) }

  it "does not enable live payments from credentials without current evidence approval" do
    allow(PlatformCapabilities).to receive(:configured?).with("stripe_live").and_return(true)
    allow(PlatformCapabilities).to receive(:enabled?).with("stripe_live").and_return(false)

    patch "/api/v1/admin/settings", params: { payment_mode: "live" }, headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("not independently approved")
    expect(SiteSetting.instance.reload.payment_mode).not_to eq("live")
  end

  it "reports configuration and evidence approval separately" do
    allow(PlatformCapabilities).to receive(:configured?).with("stripe_live").and_return(true)
    allow(PlatformCapabilities).to receive(:enabled?).with("stripe_live").and_return(false)

    get "/api/v1/admin/settings", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("stripe_live_configured" => true, "stripe_live_approved" => false)
  end
end
