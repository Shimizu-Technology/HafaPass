# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public fee terms", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  it "exposes the current all-in fee terms without authentication" do
    get "/api/v1/config"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("service_fee_percent" => "5.0", "service_fee_flat_cents" => 100,
      "processing_fee_bearer" => "platform", "payout_schedule_text" => "within 3 to 5 business days after your event",
      "organizer_payout_terms" => nil)
  end

  it "reflects admin-edited terms" do
    SiteSetting.instance.update!(service_fee_percent: 4, service_fee_flat_cents: 0, processing_fee_bearer: "organizer",
      payout_schedule_text: "within 7 days")

    get "/api/v1/config"

    expect(response.parsed_body).to include("service_fee_percent" => "4.0", "service_fee_flat_cents" => 0,
      "processing_fee_bearer" => "organizer", "payout_schedule_text" => "within 7 days")
  end

  it "exposes Copa payout terms when the promoted register is effective and approved for its current digest" do
    travel_to(Time.iso8601("2026-11-30T13:59:59Z")) do
      admin = create(:user, :admin)
      approve_register = -> { PlatformCapabilityReviews::Manager.quick_approve!(capability: "policy_register", actor: admin) }
      approve_register.call
      catalog = YAML.safe_load_file(PolicyRegistry::DOCUMENT_PATH)
      draft = catalog.fetch("draft")
      get "/api/v1/config"
      expect(response.parsed_body).to include("organizer_payout_terms" => nil)

      sections = catalog.dig("documents", "organizer-agreement", "sections")
      proposed_payouts = draft.dig("replacement_sections", "organizer-agreement").find { |section| section["heading"] == "Payouts" }
      sections.map! { |section| section["heading"] == "Payouts" ? proposed_payouts : section }
      catalog.merge!("version" => "2026-12-01-copa", "status" => "approved", "effective_date" => "2026-12-01")
      SiteSetting.instance.update!(draft.fetch("proposed_material_terms"))
      allow(PolicyRegistry).to receive(:registry).and_return(catalog)
      get "/api/v1/config"
      expect(response.parsed_body).to include("organizer_payout_terms" => nil)

      approve_register.call
      get "/api/v1/config"
      expect(response.parsed_body).to include("organizer_payout_terms" => nil)

      travel 1.second
      get "/api/v1/config"
      expect(response.parsed_body).to include("organizer_payout_terms" => "bank_transfer_with_reserve",
        "payout_schedule_text" => "within 2–3 business days after your event")

      SiteSetting.instance.update!(payout_schedule_text: "within 7 days")
      get "/api/v1/config"
      expect(response.parsed_body).to include("organizer_payout_terms" => nil)
    end
  end

  it "keeps replacement payout terms hidden when the promoted document is still a draft" do
    catalog = YAML.safe_load_file(PolicyRegistry::DOCUMENT_PATH)
    proposed = catalog.dig("draft", "replacement_sections", "organizer-agreement")
    catalog.dig("documents", "organizer-agreement")["sections"] = proposed
    catalog["status"] = "draft"
    allow(PolicyRegistry).to receive(:registry).and_return(catalog)
    allow(PolicyRegistry).to receive(:production_approved?).and_return(true)

    get "/api/v1/config"
    expect(response.parsed_body).to include("organizer_payout_terms" => nil)
  end
end
