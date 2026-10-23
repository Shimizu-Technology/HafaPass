# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrganizationInvitation do
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization) }
  let(:invitee) { create(:user, email: "team@example.com") }
  let(:membership) do
    create(:organization_membership, organization: organization, user: nil, invited_email: "TEAM@example.com",
      role: :finance, status: :invited, accepted_at: nil)
  end

  before do
    allow(ClerkIdentity).to receive(:verified_email_addresses).and_return([])
    allow(ClerkIdentity).to receive(:verified_email_addresses).with(invitee.clerk_id).and_return(["team@example.com"])
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

  it "rejects forwarded tokens after editable contact spoofing" do
    token = described_class.issue!(membership)
    attacker = create(:user, email: "attacker@example.com")
    allow(ClerkIdentity).to receive(:verified_email_addresses).with(attacker.clerk_id).and_return([attacker.email])
    attacker.update!(email: membership.invited_email)

    expect { described_class.accept!(token: token, user: attacker) }
      .to raise_error(described_class::InvitationError)
    expect(membership.reload).to be_status_invited
  end

  it "accepts verified ownership with a different contact address" do
    token = described_class.issue!(membership)
    invitee.update!(email: "contact@example.com")
    expect(described_class.accept!(token: token, user: invitee).user).to eq(invitee)
  end

  it "rejects the wrong user and expired invitations" do
    token = described_class.issue!(membership)
    wrong_user = create(:user, email: "wrong@example.com")

    expect { described_class.accept!(token: token, user: wrong_user) }
      .to raise_error(described_class::InvitationError)

    membership.update_column(:invitation_expires_at, 1.minute.ago)
    expect { described_class.accept!(token: token, user: invitee) }
      .to raise_error(described_class::InvitationError)
  end

  it "keeps an accepted teammate's access past the invitation lifetime (8th day and beyond)" do
    token = described_class.issue!(membership)
    travel 6.days
    accepted = described_class.accept!(token: token, user: invitee)

    expect(accepted.expires_at).to be_nil
    travel_to(accepted.invited_at + 8.days) do
      expect(accepted.reload).to be_effective
      expect(OrganizationMembership.effective).to include(accepted)
      expect(OrganizationAuthorization.allowed?(user: invitee, organization: organization, permission: :view_finance))
        .to be(true)
    end
    travel_to(accepted.invited_at + 400.days) { expect(accepted.reload).to be_effective }
  end

  it "reports invitation status separately from access" do
    described_class.issue!(membership)
    expect(membership.invitation_status).to eq("pending")
    travel_to(membership.invitation_expires_at + 1.second) { expect(membership.invitation_status).to eq("expired") }
    described_class.revoke!(membership)
    expect(membership.reload.invitation_status).to eq("revoked")
  end

  it "gives event access straight away to staff invited from an event" do
    profile = create(:organizer_profile, organization: organization)
    event = create(:event, organizer_profile: profile)
    membership.update!(role: :scanner, pending_event_assignments: [{ "event_id" => event.id, "role" => "scanner" }])
    token = described_class.issue!(membership)

    described_class.accept!(token: token, user: invitee)

    expect(event.event_staff_assignments.effective.where(user: invitee).pluck(:role)).to eq(["scanner"])
    expect(membership.reload.pending_event_assignments).to eq([])
    expect(OrganizationAuthorization.allowed?(user: invitee, organization: organization, permission: :scan, event: event))
      .to be(true)
  end

  it "reactivates an old revoked event assignment without its past end date" do
    profile = create(:organizer_profile, organization: organization)
    event = create(:event, organizer_profile: profile)
    create(:event_staff_assignment, organization: organization, event: event, user: invitee, role: :scanner,
      status: :revoked, expires_at: 2.days.ago)
    membership.update!(role: :scanner, pending_event_assignments: [{ "event_id" => event.id, "role" => "scanner" }])
    token = described_class.issue!(membership)

    described_class.accept!(token: token, user: invitee)

    assignment = event.event_staff_assignments.find_by!(user: invitee, role: :scanner)
    expect(assignment).to have_attributes(status: "active", expires_at: nil)
    expect(assignment).to be_effective
  end
  it "accepts a whitespace-normalized plus-address only for that exact verified address" do
    recipient = create(:user, email: "team+door@example.com")
    allow(ClerkIdentity).to receive(:verified_email_addresses).with(recipient.clerk_id).and_return(["team+door@example.com"])
    pending, token = OrganizationTeam.invite!(organization: organization, actor: create(:user, :admin),
      email: " Team+Door@Example.com  ", role: "scanner", deliver: false)
    expect(pending.invited_email).to eq("team+door@example.com")
    expect { described_class.accept!(token: token, user: invitee) }.to raise_error(described_class::InvitationError)
    expect(described_class.accept!(token: token, user: recipient)).to be_effective
  end
end
