require "rails_helper"

RSpec.describe PrivacyRequestProcessor do
  let(:admin) { create(:user, :admin) }
  let(:user) { create(:user) }
  let!(:order) { create(:order, user: user, buyer_email: user.email) }
  let(:privacy_request) do
    PrivacyRequest.create!(kind: "deletion", user: user, requester_email: user.email,
      status: "verified", verified_at: Time.current, verified_by: admin)
  end

  before do
    allow(ClerkIdentity).to receive(:delete_user).and_return(true)
    allow(EmailService).to receive(:send_privacy_request_confirmation_async)
  end

  it "shows kept and deleted records with reasons" do
    preview = described_class.new(privacy_request).preview
    expect(preview[:retained]).to include(include(table: "orders", count: 1,
      action: "anonymize"))
    expect(preview[:blockers]).to be_empty
  end

  it "anonymizes retained records, removes account contact details, and audits execution" do
    EventFavorite.create!(user: user, event: order.event)
    described_class.new(privacy_request).execute!(actor: admin)
    expect(order.reload.buyer_email).to end_with("@privacy.invalid")
    expect(order.total_cents).to eq(5250)
    expect(user.reload.email).to be_nil
    expect(EventFavorite.where(user_id: user.id)).not_to exist
    expect(privacy_request.reload.status).to eq("completed")
    expect(AuditLog.where(action: "privacy_request.executed", auditable: privacy_request)).to exist
  end

  it "blocks deletion under a legal hold" do
    LegalHold.place!(scope_type: "buyer_email", scope_value: user.email,
      reason: "Preserve this person's records", actor: admin)
    expect { described_class.new(privacy_request).execute!(actor: admin) }
      .to raise_error(PrivacyRequestProcessor::Blocked)
    expect(order.reload.buyer_email).to eq(user.email)
  end
end
