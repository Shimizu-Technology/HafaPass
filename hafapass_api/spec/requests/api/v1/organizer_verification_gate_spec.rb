# frozen_string_literal: true

require "rails_helper"

# Production's one sales gate is organizer verification: one admin action.
RSpec.describe "Organizer verification as the production sales gate", type: :request do
  let!(:admin) { create(:user, :admin, email: "leon@hafapass.example") }
  let(:owner) { create(:user, :organizer) }
  let!(:profile) do
    create(:organizer_profile, :payout_ready, user: owner).tap do |record|
      record.update!(verification_status: :unverified, verified_at: nil)
    end
  end
  let!(:event) do
    create(:event, :published, organizer_profile: profile, organization: profile.organization, starts_at: 5.days.from_now)
  end
  let!(:ticket_type) { create(:ticket_type, event: event, price_cents: 2500, quantity_available: 50) }
  let(:org_headers) { auth_headers(owner).merge("X-Organization-Id" => profile.organization_id.to_s) }

  before do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(PolicyRegistry).to receive(:production_approved?).and_return(true)
  end

  def checkout(headers: {})
    post "/api/v1/orders", params: {
      event_id: event.id, buyer_email: "buyer@example.com", buyer_name: "Jane Buyer", terms_accepted: true,
      terms_version: PolicyRegistry.buyer_terms[:version], line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }]
    }.to_json, headers: { "Content-Type" => "application/json" }.merge(headers)
  end

  it "goes from requested to selling with one admin action, and pauses with an optional note" do
    get "/api/v1/organizer/events/#{event.id}", headers: org_headers
    expect(response.parsed_body.fetch("sales_status")).to include("on_sale" => false, "reason" => "organizer_not_verified")

    expect do
      post "/api/v1/organizer_profile/submit_verification", headers: org_headers
    end.to change { MessageDelivery.where(template: "verification_request", recipient: admin.email).count }.by(1)
    expect(response).to have_http_status(:ok), response.body

    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    waiting = response.parsed_body.fetch("organizers_awaiting_verification")
    expect(waiting.first).to include("profile_id" => profile.id, "verification_status" => "pending", "payout_ready" => true)

    checkout
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body.fetch("error")).to eq("Tickets for this event are not on sale yet")

    patch "/api/v1/admin/organizer_profiles/#{profile.id}", params: { verification_status: "verified" },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    expect(response.parsed_body.fetch("verified_organizers").pluck("profile_id")).to include(profile.id)

    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive(:platform_account_id).and_return("acct_testplatform")
    allow(StripeService).to receive(:create_payment_intent)
      .and_return(OpenStruct.new(id: "pi_test_production_qa", client_secret: "pi_test_production_qa_secret_x",
        allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
    allow(StripeService).to receive(:publishable_key).and_return("pk_test_qa")
    # Production test mode is a QA tool: only platform admins buy paid tickets.
    checkout
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Paid ticket sales open soon")
    checkout(headers: auth_headers(admin))
    expect(response).to have_http_status(:created), response.body
    expect(Order.last.payments.sole).to have_attributes(provider_environment: "test",
      provider_platform_account_id: "acct_testplatform")

    patch "/api/v1/admin/organizer_profiles/#{profile.id}", params: { verification_status: "suspended" },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:ok), response.body
    get "/api/v1/organizer/events/#{event.id}", headers: org_headers
    expect(response.parsed_body.fetch("sales_status")).to include("on_sale" => false, "reason" => "organizer_paused")
    expect(AuditLog.where(action: "organizer.verification_updated", actor_user: admin).count).to eq(2)
  end

  it "lists one-click platform setup and approves the policy register" do
    allow(PolicyRegistry).to receive(:production_approved?).and_call_original

    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    setup = response.parsed_body.fetch("setup_required")
    expect(setup.find { |item| item["key"] == "policy_register" }).to include("configured" => true,
      "message" => "Checkout is off until you approve the production policy register.")

    item = setup.find { |entry| entry["key"] == "policy_register" }
    expect(item).not_to have_key("requires_draft_acknowledgment")
    post "/api/v1/admin/platform_capabilities/policy_register/quick_approve",
      headers: auth_headers(admin)
    expect(response).to have_http_status(:created), response.body
    expect(PlatformCapabilities.enabled?("policy_register")).to be(true)
    expect(AuditLog.where(action: %w[platform_capability.submitted platform_capability.approved], actor_user: admin).count)
      .to eq(2)

    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    expect(response.parsed_body.fetch("setup_required").pluck("key")).not_to include("policy_register")
  end

  it "keeps the full evidence review for Stripe live payments" do
    post "/api/v1/admin/platform_capabilities/stripe_live/quick_approve", headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("full evidence review")
  end
end
