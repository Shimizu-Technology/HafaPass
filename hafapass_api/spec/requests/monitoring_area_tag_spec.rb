# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sentry area tag", type: :request do
  it "tags a checkout request's Sentry scope, and leaves other requests untagged" do
    allow(Sentry).to receive(:set_tags).and_call_original
    post "/api/v1/orders", params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(Sentry).to have_received(:set_tags).with(area: "checkout")

    get "/api/v1/events"
    expect(Sentry).not_to have_received(:set_tags).with(area: nil)
    expect(Sentry).to have_received(:set_tags).with(area: "checkout").once
  end
end
