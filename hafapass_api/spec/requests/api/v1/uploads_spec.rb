require "rails_helper"

RSpec.describe "Api::V1 image uploads", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:owner) { profile.user }
  let(:event) { create(:event, organizer_profile: profile) }
  let(:params) { { filename: "poster.jpg", content_type: "image/jpeg", byte_size: 100 } }

  before do
    allow(S3Service).to receive(:configured?).and_return(true)
    allow(S3Service).to receive(:final_key).and_return("uploads/image.jpg")
    allow(S3Service).to receive(:delete_pending_upload)
    allow(S3Service).to receive(:generate_presigned_post).and_return({ key: "pending/image.jpg", url: "https://storage.invalid", fields: {} })
    allow(S3Service).to receive(:complete_upload).and_return({ key: "uploads/image.jpg", public_url: "https://storage.invalid/uploads/image.jpg" })
  end

  it "rejects attendee and other-organization uploads before contacting storage" do
    [create(:user), create(:organizer_profile).user].each do |attacker|
      post "/api/v1/uploads/presign", params: params.merge(event_id: event.id), headers: auth_headers(attacker), as: :json
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/uploads/presign", params: params, headers: auth_headers(attacker), as: :json
      expect(response).to have_http_status(:forbidden) if attacker.attendee?
    end
    expect(S3Service).not_to have_received(:generate_presigned_post).with(anything, anything,
      hash_including(event_id: event.id))
  end

  it "scopes event content to authorized editors and keeps finance/scanners out" do
    post "/api/v1/uploads/presign", params: params.merge(event_id: event.id), headers: auth_headers(owner), as: :json
    expect(response).to have_http_status(:ok)
    expect(S3Service).to have_received(:generate_presigned_post).with("poster.jpg", "image/jpeg",
      byte_size: 100, event_id: event.id, organization_id: event.organization_id)
    finance = create(:user)
    create(:organization_membership, organization: event.organization, user: finance, role: :finance)
    post "/api/v1/uploads/presign", params: params.merge(event_id: event.id), headers: auth_headers(finance), as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "returns a scoped completion token and publishes only after verification" do
    post "/api/v1/uploads/presign", params: params, headers: auth_headers(owner), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key("public_url")
    token = response.parsed_body.fetch("upload_token")
    post "/api/v1/uploads/complete", params: { upload_token: token }, headers: auth_headers(create(:user)), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(S3Service).not_to have_received(:complete_upload)
    post "/api/v1/uploads/complete", params: { upload_token: token }, headers: auth_headers(owner), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("public_url")).to include("uploads/image.jpg")
  end

  it "rechecks event permissions at completion" do
    marketer = create(:user)
    membership = create(:organization_membership, organization: event.organization, user: marketer, role: :marketer)
    headers = auth_headers(marketer)
    post "/api/v1/uploads/presign", params: params.merge(event_id: event.id), headers: headers, as: :json
    token = response.parsed_body.fetch("upload_token")
    membership.update!(status: :revoked)
    post "/api/v1/uploads/complete", params: { upload_token: token }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(S3Service).not_to have_received(:complete_upload)
  end

  it "replays a lost response without another copy and cleans only after durable success" do
    post "/api/v1/uploads/presign", params: params, headers: auth_headers(owner), as: :json
    token = response.parsed_body.fetch("upload_token")
    allow(S3Service).to receive(:delete_pending_upload) do |key|
      receipt = ImageUploadReceipt.find_by!(source_key: key)
      expect(receipt.completed_at).to be_present
      expect(receipt.public_url).to eq("https://storage.invalid/uploads/image.jpg")
    end
    2.times do
      post "/api/v1/uploads/complete", params: { upload_token: token }, headers: auth_headers(owner), as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("key" => "uploads/image.jpg", "public_url" => "https://storage.invalid/uploads/image.jpg")
    end
    expect(ImageUploadReceipt.count).to eq(1)
    expect(S3Service).to have_received(:complete_upload).once
  end

  it "retains one destination after an uncertain copy and retries verification before deleting its source" do
    post "/api/v1/uploads/presign", params: params, headers: auth_headers(owner), as: :json
    token = response.parsed_body.fetch("upload_token")
    allow(S3Service).to receive(:complete_upload).and_raise(S3Service::UploadError, "Verification interrupted")
    post "/api/v1/uploads/complete", params: { upload_token: token }, headers: auth_headers(owner), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    receipt = ImageUploadReceipt.sole
    expect(receipt.completed_at).to be_nil
    expect(S3Service).not_to have_received(:delete_pending_upload)
    allow(S3Service).to receive(:complete_upload).and_return(key: receipt.final_key, public_url: "https://storage.invalid/#{receipt.final_key}")
    post "/api/v1/uploads/complete", params: { upload_token: token }, headers: auth_headers(owner), as: :json
    expect(response).to have_http_status(:ok)
    expect(ImageUploadReceipt.sole.id).to eq(receipt.id)
    expect(S3Service).to have_received(:final_key).once
    expect(S3Service).to have_received(:complete_upload).with(hash_including(final_key: receipt.final_key)).twice
    expect(S3Service).to have_received(:delete_pending_upload).once
  end

  it "still enforces current permissions on a completed receipt" do
    marketer = create(:user)
    membership = create(:organization_membership, organization: event.organization, user: marketer, role: :marketer)
    headers = auth_headers(marketer)
    post "/api/v1/uploads/presign", params: params.merge(event_id: event.id), headers: headers, as: :json
    token = response.parsed_body.fetch("upload_token")
    post "/api/v1/uploads/complete", params: { upload_token: token }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    membership.update!(status: :revoked)
    post "/api/v1/uploads/complete", params: { upload_token: token }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(S3Service).to have_received(:complete_upload).once
  end

  it "does not let a non-financial completion receipt prevent draft event deletion" do
    post "/api/v1/uploads/presign", params: params.merge(event_id: event.id), headers: auth_headers(owner), as: :json
    token = response.parsed_body.fetch("upload_token")
    post "/api/v1/uploads/complete", params: { upload_token: token }, headers: auth_headers(owner), as: :json
    expect(response).to have_http_status(:ok)
    expect { event.destroy! }.to change(ImageUploadReceipt, :count).from(1).to(0)
  end

  it "rejects invalid/expired tokens and fails closed without storage" do
    post "/api/v1/uploads/complete", params: { upload_token: "forged" }, headers: auth_headers(owner), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    token = SignedCredential.issue(namespace: "image_upload", payload: { user_id: owner.id }, expires_at: 1.second.ago)
    post "/api/v1/uploads/complete", params: { upload_token: token }, headers: auth_headers(owner), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    allow(S3Service).to receive(:configured?).and_return(false)
    post "/api/v1/uploads/presign", params: params, headers: auth_headers(owner), as: :json
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body["error"]).to include("without an image")
  end
end
