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

  it "does not let a business validation rescue swallow rejected audit validation" do
    admin = create(:user, :admin)
    profile = create(:organizer_profile)
    headers = auth_headers(admin)
    rejected = AuditLog.new
    rejected.errors.add(:base, "Rejected audit")
    allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(rejected))
    expect do
      patch "/api/v1/admin/organizer_profiles/#{profile.id}", params: { verification_status: "verified" }, headers: headers
    end.to raise_error(AuditLogger::WriteError)
    expect(profile.reload).to be_verification_status_unverified
  end

  it "rolls back a support note if audit validation fails" do
    support = create(:user, role: :support)
    event = create(:event)
    headers = auth_headers(support)
    rejected = AuditLog.new
    rejected.errors.add(:base, "Rejected audit")
    allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(rejected))
    expect do
      post "/api/v1/support/notes", params: { event_id: event.id, body: "Checked the event" }, headers: headers
    end.to raise_error(AuditLogger::WriteError)
    expect(SupportNote.where(event: event)).to be_empty
  end
end
