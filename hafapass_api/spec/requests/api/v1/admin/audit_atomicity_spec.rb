# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Privileged audit atomicity", type: :request do
  it "rolls back a platform role update if audit storage fails" do
    admin = create(:user, :admin)
    target = create(:user)
    headers = auth_headers(admin)
    allow(AuditLogger).to receive(:record!).and_raise("audit unavailable")
    expect { patch "/api/v1/admin/users/#{target.id}", params: { role: "support" }, headers: headers }
      .to raise_error("audit unavailable")
    expect(target.reload).to be_attendee
  end

  it "rolls back verification when the audit fails" do
    admin = create(:user, :admin)
    profile = create(:organizer_profile)
    headers = auth_headers(admin)
    allow(AuditLogger).to receive(:record!).and_raise("audit unavailable")
    expect do
      patch "/api/v1/admin/organizer_profiles/#{profile.id}", params: { verification_status: "verified" }, headers: headers
    end.to raise_error("audit unavailable")
    expect(profile.reload).to be_verification_status_unverified
  end
end
