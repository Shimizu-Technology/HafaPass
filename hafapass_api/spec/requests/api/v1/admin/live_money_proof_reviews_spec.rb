require "rails_helper"

RSpec.describe "Admin live-money proof controls", type: :request do
  it "shows the redacted authorization and organization Gate H status" do
    chain = create_live_money_proof_chain
    admin = create(:user, :admin)

    get "/api/v1/admin/events/#{chain[:event].id}/live_money_proof", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("authorization")).to include(
      "id" => chain[:authorization].id, "order_id" => chain[:order].id
    )
    expect(response.body).not_to include(chain[:authorization].buyer_email_digest)
    expect(response.parsed_body.fetch("live_money_proof")).to include("approved" => false)
  end

  it "does not advertise a stale authorization as available" do
    chain = create_live_money_proof_chain
    chain[:authorization].update_columns(order_id: nil, consumed_at: nil)

    get "/api/v1/admin/events/#{chain[:event].id}/live_money_proof",
      headers: auth_headers(create(:user, :admin))

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("authorization")).to include("available" => false)
  end

  it "submits and independently approves complete Gate H evidence" do
    chain = create_live_money_proof_chain
    submitter = create(:user, :admin)
    approver = create(:user, :admin)

    post "/api/v1/admin/events/#{chain[:event].id}/live_money_proof_reviews",
      params: chain[:attributes], headers: auth_headers(submitter)

    expect(response).to have_http_status(:created)
    submission_id = response.parsed_body.fetch("id")
    expect(response.parsed_body).to include("proof_event_id" => chain[:event].id,
      "connected_account_id" => chain[:organization].payout_account.id)

    post "/api/v1/admin/live_money_proof_reviews/#{submission_id}/approve", headers: auth_headers(approver)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("decision" => "approval", "active" => true)
  end

  it "rejects malformed structured evidence without a server error" do
    chain = create_live_money_proof_chain

    post "/api/v1/admin/events/#{chain[:event].id}/live_money_proof_reviews",
      params: chain[:attributes].merge(reconciliation_results: "everything matched"),
      headers: auth_headers(create(:user, :admin))

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("must be an integer")
    expect(LiveMoneyProofReview.count).to eq(0)
  end

  it "does not expose finance evidence through admin routes to an organizer" do
    chain = create_live_money_proof_chain

    get "/api/v1/admin/events/#{chain[:event].id}/live_money_proof",
      headers: auth_headers(create(:user, :organizer))

    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("restricted-finance")
  end
end
