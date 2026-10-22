# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Production launch behaviour", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:admin) { create(:user, :admin, email: "leon@hafapass.example") }
  let(:profile) { create(:organizer_profile, :payout_ready) }
  let(:event) do
    create(:event, :published, organizer_profile: profile, organization: profile.organization, starts_at: 5.days.from_now)
  end
  let(:org_headers) { auth_headers(profile.user).merge("X-Organization-Id" => profile.organization_id.to_s) }

  before do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(PolicyRegistry).to receive(:production_approved?).and_return(true)
  end

  def paid_order(environment:, total: 1000)
    order = create(:order, event: event, subtotal_cents: total, service_fee_cents: 0, total_cents: total)
    create(:payment, :succeeded, order: order, amount_cents: total, provider_environment: environment,
      provider_platform_account_id: environment == "live" ? "acct_liveplatform" : "acct_testplatform")
    order
  end

  it "leaves test-mode orders out of revenue, analytics and exports but labels them in order lists" do
    live = paid_order(environment: "live", total: 3000)
    test = paid_order(environment: "test", total: 2000)
    cash = create(:order, event: event, subtotal_cents: 500, service_fee_cents: 0, total_cents: 500, payment_method: "door_cash")

    expect(Order.excluding_test_payments).to include(live, cash)
    expect(Order.excluding_test_payments).not_to include(test)
    expect(Commerce::LedgerTotals.call(event.orders)[:gross_cents]).to eq(3500)

    get "/api/v1/admin/orders", headers: auth_headers(admin)
    flags = response.parsed_body.fetch("orders").to_h { |order| [order["id"], order["test_payment"]] }
    expect(flags).to include(test.id => true, live.id => false)
  end

  it "counts every order outside production" do
    paid_order(environment: "test", total: 2000)
    allow(Rails.env).to receive(:production?).and_return(false)

    expect(Commerce::LedgerTotals.call(event.orders)[:gross_cents]).to eq(2000)
  end

  it "lets an admin resume sales a pilot run paused, and shows the organizer why sales stopped" do
    chain = create_live_pilot_run(event: nil)
    run_event = chain[:event]
    LivePilotRuns::Manager.pause!(run: chain[:run], actor: admin, reason: "Scanner battery check")
    run_event.update_column(:description, "Edited after the approval") # Gate I approval lapses; run stays open

    expect(LivePilot.current_run(run_event)).to eq(chain[:run])
    expect(run_event.reload.sales_status).to include(on_sale: false, reason: "sales_paused",
      message: "Sales paused by HåfaPass: Scanner battery check.")

    delete "/api/v1/admin/events/#{run_event.id}/sales_suspension", params: { note: "Checked" },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:ok), response.body
    expect(run_event.reload.sales_suspended_at).to be_nil
    expect(AuditLog.where(action: "event.sales_resumed", actor_user: admin)).to exist
  end

  it "emails admins once when an organizer moves into pending, not on every click" do
    profile.update!(verification_status: :unverified, verified_at: nil)
    event

    post "/api/v1/organizer_profile/submit_verification", headers: org_headers
    expect(MessageDelivery.where(template: "verification_request", recipient: admin.email).count).to eq(1)

    expect do
      post "/api/v1/organizer_profile/submit_verification", headers: org_headers
    end.not_to change(MessageDelivery, :count)
  end

  it "lets unverified organizers publish in production while tickets stay off sale" do
    profile.update!(verification_status: :unverified, verified_at: nil)
    draft = create(:event, organizer_profile: profile, organization: profile.organization, starts_at: 5.days.from_now,
      max_capacity: 50)
    create(:ticket_type, :free, event: draft, quantity_available: 50)

    item = draft.publish_checklist.find { |entry| entry[:code] == "organizer_verified" }
    expect(item).to include(complete: false, required_to_publish: false)
    EventLifecycle.call(event: draft, action: :publish, actor: profile.user)
    expect(draft.reload).to be_published
    expect(draft.sales_status).to include(on_sale: false, reason: "organizer_not_verified")
  end

  it "still requires verification to publish outside production" do
    allow(Rails.env).to receive(:production?).and_return(false)
    profile.update!(verification_status: :unverified, verified_at: nil)
    draft = create(:event, organizer_profile: profile, organization: profile.organization, starts_at: 5.days.from_now)

    expect(draft.publish_checklist.find { |entry| entry[:code] == "organizer_verified" })
      .to include(required_to_publish: true)
  end

  it "versions the scanner manifest when the payment mode switches" do
    allow(Admissions::ManifestSigner).to receive_messages(sign: "signature", key_id: "key-1")
    SiteSetting.instance.update!(payment_mode: "test")
    first = Admissions::ManifestBuilder.call(event: event, actor: admin)
    expect(Admissions::ManifestBuilder.call(event: event, actor: admin)).to eq(first)

    SiteSetting.instance.update_column(:payment_mode, "live")
    second = Admissions::ManifestBuilder.call(event: event, actor: admin)
    expect(second.version).to eq(first.version + 1)
  end

  it "refuses simulate in production and warns before quick approvals expire" do
    patch "/api/v1/admin/settings", params: { payment_mode: "simulate" }, headers: auth_headers(admin)
    SiteSetting.instance.update_column(:payment_mode, "test")
    patch "/api/v1/admin/settings", params: { payment_mode: "simulate" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("test or live payments only")
    expect(SiteSetting.instance.reload.payment_mode).to eq("test")

    allow(PolicyRegistry).to receive(:production_approved?).and_call_original
    allow(PolicyRegistry).to receive(:draft?).and_return(false)
    PlatformCapabilityReviews::Manager.quick_approve!(capability: "policy_register", actor: admin)
    travel_to(PlatformCapabilityReviews::Manager::QUICK_APPROVAL_TERM.from_now - 10.days) do
      get "/api/v1/admin/dashboard", headers: auth_headers(admin)
      item = response.parsed_body.fetch("setup_required").find { |entry| entry["key"] == "policy_register" }
      expect(item).to include("expiring_soon" => true)
      expect(item["message"]).to include("expires on")
      expect(PlatformCapabilities.readiness.dig(:capabilities, "policy_register", :expiring_soon)).to be(true)
    end
  end

  it "lists paused organizers with their note" do
    profile.update!(verification_status: :suspended, verification_notes: nil)

    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    expect(response.parsed_body.fetch("suspended_organizers").pluck("profile_id")).to include(profile.id)
  end

  it "marks events of unverified organizers as not purchasable on organizer pages" do
    create(:ticket_type, :free, event: event, quantity_available: 20)
    profile.update!(verification_status: :pending)

    get "/api/v1/organizers/#{profile.organization.slug}"
    listed = response.parsed_body.fetch("events").find { |item| item["id"] == event.id }
    expect(listed).to include("purchasable" => false) if listed
  end
end
