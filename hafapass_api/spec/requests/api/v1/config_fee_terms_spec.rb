# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public fee terms", type: :request do
  it "exposes the current all-in fee terms without authentication" do
    get "/api/v1/config"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("service_fee_percent" => "5.0", "service_fee_flat_cents" => 100,
      "processing_fee_bearer" => "platform", "payout_schedule_text" => "within 3 to 5 business days after your event")
  end

  it "reflects admin-edited terms" do
    SiteSetting.instance.update!(service_fee_percent: 4, service_fee_flat_cents: 0, processing_fee_bearer: "organizer",
      payout_schedule_text: "within 7 days")

    get "/api/v1/config"

    expect(response.parsed_body).to include("service_fee_percent" => "4.0", "service_fee_flat_cents" => 0,
      "processing_fee_bearer" => "organizer", "payout_schedule_text" => "within 7 days")
  end
end
