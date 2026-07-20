# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrganizationInvitation do
  let(:organization) { create(:organization) }
  let(:invitee) { create(:user, email: "team@example.com") }
  let(:membership) do
    create(:organization_membership, organization: organization, user: nil, invited_email: "TEAM@example.com",
      role: :finance, status: :invited, accepted_at: nil)
  end

  it "accepts an email-bound invitation once and rotates its version" do
    token = described_class.issue!(membership)

    expect do
      described_class.accept!(token: token, user: invitee)
    end.to change { membership.reload.status }.from("invited").to("active")
      .and change { membership.reload.invitation_version }.from(1).to(2)

    expect(membership.user).to eq(invitee)
    expect(membership.accepted_at).to be_present
    expect { described_class.accept!(token: token, user: invitee) }
      .to raise_error(described_class::InvitationError, "Invitation is invalid or expired")
  end

  it "rejects the wrong user and expired invitations" do
    token = described_class.issue!(membership)
    wrong_user = create(:user, email: "wrong@example.com")

    expect { described_class.accept!(token: token, user: wrong_user) }
      .to raise_error(described_class::InvitationError)

    membership.update_column(:expires_at, 1.minute.ago)
    expect { described_class.accept!(token: token, user: invitee) }
      .to raise_error(described_class::InvitationError)
  end
end
