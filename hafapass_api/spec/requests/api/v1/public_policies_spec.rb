# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public policies", type: :request do
  it "serves every operative policy without sign-in and keeps review notes private" do
    get "/api/v1/config"

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body).to include("buyer_terms_version" => "2026-10-24", "policy_status" => "approved",
      "policy_effective_date" => "2026-10-24")
    expect(body.fetch("policies").keys).to include("buyer-terms", "refunds", "privacy", "cookies",
      "accessibility", "organizer-agreement")
    expect(body.fetch("policies").to_json).not_to match(/draft|pending counsel|subject to review|not final|Counsel to|Lawyer to|Accountant to/i)
    expect(body).not_to have_key("review_notes")
  end

  it "serves an individual policy's share metadata without sign-in" do
    get "/og/policies/organizer-agreement"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/html")
    expect(response.body).to include("<title>Organizer Agreement | HåfaPass</title>",
      'property="og:title" content="Organizer Agreement"',
      "/policies/organizer-agreement")
    expect(response.body).not_to match(/draft|Counsel to|Accountant to/i)

    get "/og/policies/not-a-policy"
    expect(response).to have_http_status(:not_found)
  end
end
