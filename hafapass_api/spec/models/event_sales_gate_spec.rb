# frozen_string_literal: true

require "rails_helper"

# Production's one sales gate replaces the per-event launch gates.
RSpec.describe "Event sales gate in production" do
  let(:profile) { create(:organizer_profile, :payout_ready) }
  let(:event) do
    create(:event, :published, organizer_profile: profile, organization: profile.organization, starts_at: 5.days.from_now)
  end

  before do
    create(:ticket_type, event: event, price_cents: 2500, quantity_available: 50)
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(PolicyRegistry).to receive(:production_approved?).and_return(true)
    SiteSetting.instance.update!(payment_mode: "test")
  end

  it "sells once the organizer is verified, without any per-event gate reviews" do
    expect(event.sales_open?).to be(true)
    expect(event.sales_status).to eq(on_sale: true, reason: nil, message: "On sale.")
  end

  it "keeps selling after a deploy changes the application revision" do
    allow(ApplicationRevision).to receive(:current).and_return("a" * 40)
    expect(event.sales_open?).to be(true)
    allow(ApplicationRevision).to receive(:current).and_return("b" * 40)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("RENDER_GIT_COMMIT").and_return("c" * 40)

    expect(event.reload.sales_open?).to be(true)
    expect(event.sales_blocker).to be_nil
  end

  it "keeps selling after the organizer edits the description, cover, and short description" do
    url = "https://storage.invalid/uploads/new-cover.jpg"
    ImageUploadReceipt.create!(user: event.organizer_profile.user, organization: event.organization,
      source_key: "pending/new-cover", final_key: "uploads/new-cover.jpg", public_url: url, completed_at: Time.current)
    event.update!(description: "New details", short_description: "Now with food trucks", cover_image_url: url)

    expect(event.reload.sales_open?).to be(true)
  end

  it "stops selling and explains why until HåfaPass verifies the organizer" do
    profile.update!(verification_status: :unverified, verified_at: nil)

    expect(event.reload.sales_open?).to be(false)
    expect(event.sales_status).to include(on_sale: false, reason: "organizer_not_verified")
    expect(event.sales_status[:message]).to include("Visible but not on sale yet", "verify your organization")

    profile.update!(verification_status: :pending)
    expect(event.reload.sales_blocker).to eq(:organizer_verification_requested)
  end

  it "pauses every sale for the organizer when verification is suspended, with an optional note" do
    profile.update!(verification_status: :suspended, verification_notes: nil)

    expect(event.reload.sales_blocker).to eq(:organizer_paused)
    expect(event.sales_open?).to be(false)
  end

  it "shows a HåfaPass event pause plainly" do
    EventPolicyHold.place!(event: event, actor: create(:user, :admin), scope: "sales", reason: "Venue permit check")

    expect(event.reload.sales_status).to include(on_sale: false, reason: "event_paused")
  end

  it "requires test or live payments and payout details for paid tickets only" do
    SiteSetting.instance.update!(payment_mode: "simulate")
    expect(event.sales_blocker).to eq(:payments_off)

    SiteSetting.instance.update!(payment_mode: "test")
    allow(event.organization).to receive(:payout_ready?).and_return(false)
    expect(event.sales_blocker).to eq(:payout_details_missing)
  end

  it "drops the launch-gate checklist items; organizer verification is the admin step" do
    codes = event.publish_checklist.pluck(:code)

    expect(codes).to include("organizer_verified", "payout")
    expect(codes).not_to include("pilot_readiness_approved", "pilot_validation_approved", "event_day_rehearsal_approved",
      "live_money_approved", "live_pilot_approved", "production_policy_approved")
    expect(event.ready_to_publish?).to be(true)
  end
end
