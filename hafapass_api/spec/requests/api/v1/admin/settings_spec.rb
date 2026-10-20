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

  describe "fee terms" do
    it "updates the fee, processing bearer and payout schedule with an audit record" do
      patch "/api/v1/admin/settings", params: { service_fee_percent: "4.5", service_fee_flat_cents: 75,
        processing_fee_bearer: "organizer", payout_schedule_text: "  within 5 business days  " }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("service_fee_percent" => "4.5", "service_fee_flat_cents" => 75,
        "processing_fee_bearer" => "organizer", "payout_schedule_text" => "within 5 business days")
      audit = AuditLog.find_by!(action: "site_settings.fee_terms_updated")
      expect(audit.actor_user).to eq(admin)
      expect(audit.before_data).to include("service_fee_percent" => "5.0", "processing_fee_bearer" => "platform")
      expect(audit.after_data).to include("service_fee_percent" => "4.5", "service_fee_flat_cents" => "75",
        "processing_fee_bearer" => "organizer", "payout_schedule_text" => "within 5 business days")
    end

    it "does not audit a save that leaves fee terms unchanged" do
      patch "/api/v1/admin/settings", params: { platform_phone: "671-555-0100" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(AuditLog.where(action: "site_settings.fee_terms_updated")).to be_empty
    end

    [
      { processing_fee_bearer: "buyer" },
      { service_fee_percent: "-1" },
      { service_fee_percent: "25.01" },
      { service_fee_percent: "abc" },
      { service_fee_flat_cents: "1001" },
      { service_fee_flat_cents: "1.5" },
      { payout_schedule_text: " " },
      { payout_schedule_text: "x" * 201 }
    ].each do |invalid|
      it "rejects #{invalid.keys.first} #{invalid.values.first.to_s.first(12).inspect} without changing settings" do
        patch "/api/v1/admin/settings", params: invalid, headers: auth_headers(admin)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch("errors")).not_to be_empty
        expect(SiteSetting.instance.reload).to have_attributes(service_fee_percent: 5.0, service_fee_flat_cents: 100,
          processing_fee_bearer: "platform", payout_schedule_text: "within 3 business days after your event")
        expect(AuditLog.where(action: "site_settings.fee_terms_updated")).to be_empty
      end
    end

    it "keeps fee terms admin-only" do
      patch "/api/v1/admin/settings", params: { service_fee_percent: "1" }, headers: auth_headers(create(:user))

      expect(response).to have_http_status(:forbidden)
      expect(SiteSetting.instance.reload.service_fee_percent).to eq(5.0)
    end
  end
end
