require "rails_helper"

RSpec.describe "Api::V1::OrganizerProfiles", type: :request do
  let(:user) { create(:user, :organizer) }
  let!(:profile) { create(:organizer_profile, user: user) }
  let(:headers) { auth_headers(user) }

  it "includes the image host in the profile response for configured, local, and unavailable storage" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    ["synthetic-bucket", nil].each do |bucket|
      allow(ENV).to receive(:[]).with("AWS_BUCKET").and_return(bucket)
      allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return(bucket)
      get "/api/v1/organizer_profile", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["image_asset_host"]).to eq(S3Service.public_asset_host)
      expect(response.parsed_body["image_asset_host"]).to eq(bucket ? "synthetic-bucket.s3.us-west-2.amazonaws.com" : "storage.invalid")
    end
    allow(Rails.env).to receive(:local?).and_return(false)
    get "/api/v1/organizer_profile", headers: headers
    expect(response.parsed_body).to include("image_asset_host" => nil)
  end

  it "does not let an organizer assign partner status" do
    put "/api/v1/organizer_profile", params: { business_name: profile.business_name, is_ambros_partner: true }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(profile.reload.is_ambros_partner).to be(false)
  end

  it "records explicit policy acceptance" do
    post "/api/v1/organizer_profile/accept_policy", headers: headers

    expect(response).to have_http_status(:ok)
    expect(profile.reload).to have_attributes(
      policy_version: PolicyRegistry.organizer_agreement[:version],
      policy_digest: PolicyRegistry.organizer_agreement[:digest]
    )
    expect(profile.policy_accepted_at).to be_present
    expect(profile).to be_policy_accepted
  end

  it "submits a complete profile for verification" do
    post "/api/v1/organizer_profile/submit_verification", headers: headers,
      params: { business_name: "Island Events", business_description: "Community events on Guam",
        verification_phone: "+1 (671) 555-1234", verification_link: "https://instagram.com/islandevents",
        verification_request_note: "Our first event is next month." }

    expect(response).to have_http_status(:ok)
    expect(profile.reload).to be_verification_status_pending
    expect(profile.verification_requested_at).to be_present
    expect(profile).to have_attributes(verification_phone: "+1 (671) 555-1234",
      verification_link: "https://instagram.com/islandevents")
    expect(profile.organization.reload.name).to eq("Island Events")
  end

  it "normalizes bare social links and rejects unsafe schemes and invalid hosts" do
    details = { business_name: "Island Events", business_description: "Community events",
      verification_phone: "+1-671-555-1234", verification_link: "instagram.com/islandevents" }
    post "/api/v1/organizer_profile/submit_verification", headers: headers, params: details
    expect(response).to have_http_status(:ok)
    expect(profile.reload.verification_link).to eq("https://instagram.com/islandevents")

    %w[javascript:alert(1) https://localhost https://bad_host/path].each do |unsafe|
      post "/api/v1/organizer_profile/submit_verification", headers: headers,
        params: details.merge(verification_link: unsafe)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  it "rolls back the verification request when the organization name cannot be saved" do
    original_name = profile.organization.name
    profile.organization.update_columns(marketing_address_certified_at: Time.current,
      marketing_mailing_address: "invalid")

    post "/api/v1/organizer_profile/submit_verification", headers: headers,
      params: { business_name: "Island Events", business_description: "Community events",
        verification_phone: "+1-671-555-1234", verification_link: "https://example.com/events" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors").join).to include("Marketing mailing address")
    expect(profile.reload).to be_verification_status_unverified
    expect(profile.organization.reload.name).to eq(original_name)
  end

  it "retains the profile state when verification contact details are invalid" do
    post "/api/v1/organizer_profile/submit_verification", headers: headers,
      params: { business_name: "Island Events", business_description: "Community events",
        verification_phone: "123", verification_link: "javascript:alert(1)" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors").join).to include("Verification phone", "Verification link")
    expect(profile.reload).to be_verification_status_unverified
  end

  it "versions pending edits, notifies admins again, shows the diff, and rejects a stale approval" do
    admin = create(:user, :admin)
    create(:event, :published, organizer_profile: profile, organization: profile.organization)
    details = { business_name: "Island Events", business_description: "Community events",
      verification_phone: "+1-671-555-1234", verification_link: "https://example.com/events" }
    post "/api/v1/organizer_profile/submit_verification", headers: headers, params: details
    expect(response).to have_http_status(:ok)
    first_version = profile.reload.verification_request_version
    first_time = profile.verification_requested_at
    expect(MessageDelivery.where(template: "verification_request", recipient: admin.email).count).to eq(1)

    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    opened = response.parsed_body.fetch("organizers_awaiting_verification").find { |item| item["profile_id"] == profile.id }
    expect(opened.fetch("verification_request_version")).to eq(first_version)

    put "/api/v1/organizer_profile", headers: headers,
      params: { business_name: "Island Events Guam", business_description: "Community events" }
    expect(response).to have_http_status(:ok)
    expect(profile.reload.verification_requested_at).to be > first_time
    expect(profile.verification_request_version).to eq(first_version + 1)
    expect(MessageDelivery.where(template: "verification_request", recipient: admin.email).count).to eq(2)
    expect(MessageDelivery.where(template: "verification_request", recipient: admin.email).last.metadata["updated"]).to be(true)
    expect(AuditLog.where(action: "organizer.verification_request_updated", actor_user: user)).to exist

    patch "/api/v1/admin/organizer_profiles/#{profile.id}", headers: auth_headers(admin),
      params: { verification_status: "verified", verification_request_version: opened.fetch("verification_request_version") }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to eq("This request changed — reload to review the latest details.")
    expect(profile.reload).to be_verification_status_pending

    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    refreshed = response.parsed_body.fetch("organizers_awaiting_verification").find { |item| item["profile_id"] == profile.id }
    expect(refreshed.fetch("verification_change_diff")).to include("business_name" => {
      "before" => "Island Events", "after" => "Island Events Guam" })
    expect(refreshed).to include("business_description" => "Community events")
    patch "/api/v1/admin/organizer_profiles/#{profile.id}", headers: auth_headers(admin),
      params: { verification_status: "verified", verification_request_version: refreshed.fetch("verification_request_version") }
    expect(response).to have_http_status(:ok)
  end

  it "keeps all pending field changes until an admin reviews the current request" do
    admin = create(:user, :admin)
    details = { business_name: "Island Events", business_description: "Community events",
      verification_phone: "+1-671-555-1234", verification_link: "www.instagram.com/islandevents" }
    post "/api/v1/organizer_profile/submit_verification", headers: headers, params: details
    put "/api/v1/organizer_profile", headers: headers,
      params: { business_name: "Island Events Guam", business_description: "Community events" }
    post "/api/v1/organizer_profile/submit_verification", headers: headers,
      params: details.merge(business_name: "Island Events Guam", verification_phone: "+1-671-555-5678")

    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    pending = response.parsed_body.fetch("organizers_awaiting_verification").find { |item| item["profile_id"] == profile.id }
    expect(pending.fetch("verification_change_diff")).to include(
      "business_name" => { "before" => "Island Events", "after" => "Island Events Guam" },
      "verification_phone" => { "before" => "+1-671-555-1234", "after" => "+1-671-555-5678" }
    )
    expect(pending).to include("business_description" => "Community events",
      "verification_request_note" => nil)
  end

  it "lets a legacy pending organizer edit its name while contact fields remain blank" do
    profile.update!(verification_status: :pending, verification_phone: nil, verification_link: nil)
    original_name = profile.business_name
    before_version = profile.verification_request_version

    put "/api/v1/organizer_profile", headers: headers,
      params: { business_name: "Legacy Island Events", business_description: "Community events" }

    expect(response).to have_http_status(:ok)
    expect(profile.reload.verification_request_version).to eq(before_version + 1)
    expect(profile.verification_change_diff).to include("business_name" => {
      "before" => original_name, "after" => "Legacy Island Events" })
  end

  it "ignores an empty reviewer note when a pending request is otherwise unchanged" do
    admin = create(:user, :admin)
    details = { business_name: "Island Events", business_description: "Community events",
      verification_phone: "+1-671-555-1234", verification_link: "https://example.com/events" }
    post "/api/v1/organizer_profile/submit_verification", headers: headers, params: details
    version = profile.reload.verification_request_version
    notices = MessageDelivery.where(template: "verification_request", recipient: admin.email).count

    post "/api/v1/organizer_profile/submit_verification", headers: headers,
      params: details.merge(verification_request_note: "")

    expect(response).to have_http_status(:ok)
    expect(profile.reload.verification_request_version).to eq(version)
    expect(profile.verification_change_diff).to eq({})
    expect(MessageDelivery.where(template: "verification_request", recipient: admin.email).count).to eq(notices)
  end

  it "reopens review for a pending verification form edit even within the notice interval" do
    admin = create(:user, :admin)
    create(:event, :published, organizer_profile: profile, organization: profile.organization)
    details = { business_name: "Island Events", business_description: "Community events",
      verification_phone: "+1-671-555-1234", verification_link: "https://example.com/events" }
    post "/api/v1/organizer_profile/submit_verification", headers: headers, params: details
    first_version = profile.reload.verification_request_version
    post "/api/v1/organizer_profile/submit_verification", headers: headers,
      params: details.merge(verification_phone: "+1-671-555-5678")
    expect(response).to have_http_status(:ok)
    expect(profile.reload.verification_request_version).to eq(first_version + 1)
    expect(profile.verification_change_diff.fetch("verification_phone")).to include("after" => "+1-671-555-5678")
    expect(MessageDelivery.where(template: "verification_request", recipient: admin.email).count).to eq(2)
  end

  it "notifies admins of an updated request before the organizer creates an event" do
    admin = create(:user, :admin)
    details = { business_name: "Island Events", business_description: "Community events",
      verification_phone: "+1-671-555-1234", verification_link: "https://example.com/events" }
    post "/api/v1/organizer_profile/submit_verification", headers: headers, params: details
    post "/api/v1/organizer_profile/submit_verification", headers: headers,
      params: details.merge(verification_request_note: "New address on our website")
    expect(MessageDelivery.where(template: "verification_request", recipient: admin.email).count).to eq(2)
  end
end
