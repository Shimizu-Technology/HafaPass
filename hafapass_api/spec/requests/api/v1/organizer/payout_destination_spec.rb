# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Selecting the payout destination", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:headers) { auth_headers(profile.user).merge("X-Organization-Id" => organization.id.to_s) }
  let(:details) { { payee_name: "Island Events LLC", delivery_method: "mail", mailing_address: "PO Box 1, Hagåtña GU 96910" } }

  [%w[manual check], %w[check manual]].each do |order|
    it "uses the selected check regardless of creation order #{order.join(', ')} and survives reload" do
      accounts = order.to_h do |provider|
        [provider, create(:connected_account, organization: organization, provider: provider,
          payout_details: provider == "check" ? details.stringify_keys : {})]
      end
      patch "/api/v1/organizer/connected_accounts/#{accounts.fetch('check').id}", headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body["selected"]).to be(true)
      expect(organization.reload.payout_account).to eq(accounts.fetch("check"))
      expect(organization).to be_payout_ready
      patch "/api/v1/organizer/connected_accounts/#{accounts.fetch('manual').id}", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(organization.reload.payout_account).to eq(accounts.fetch("check"))
      get "/api/v1/organizer/connected_accounts", headers: headers
      expect(response.parsed_body.select { |account| account["selected"] }.pluck("id")).to eq([accounts.fetch("check").id])
    end
  end

  it "switches supported destinations explicitly, audits both IDs and never falls back to another ready account" do
    first = create(:connected_account, organization: organization)
    check = create(:connected_account, organization: organization, provider: "check", payout_details: details.stringify_keys)
    patch "/api/v1/organizer/connected_accounts/#{check.id}", headers: headers
    expect(organization.reload.payout_account).to eq(check)
    audit = AuditLog.find_by!(action: "connected_account.destination_selected", auditable: check)
    expect(audit.before_data["payout_connected_account_id"]).to eq(first.id)
    expect(audit.after_data["payout_connected_account_id"]).to eq(check.id)
    check.update!(status: :disabled)
    expect(organization.reload.payout_account).to be_nil
    expect(organization).not_to be_payout_ready
    patch "/api/v1/organizer/connected_accounts/#{first.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(organization.reload.payout_account).to eq(first)
  end

  it "rejects foreign accounts and blocks switching during a reserved payout" do
    first = create(:connected_account, organization: organization)
    check = create(:connected_account, organization: organization, provider: "check", payout_details: details.stringify_keys)
    event = create(:event, organization: organization, organizer_profile: profile)
    create(:payout, organization: organization, event: event, connected_account: first)
    patch "/api/v1/organizer/connected_accounts/#{check.id}", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(organization.reload.payout_connected_account_id).to eq(first.id)
    foreign = create(:connected_account)
    patch "/api/v1/organizer/connected_accounts/#{foreign.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    expect { organization.update!(payout_connected_account: foreign) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
