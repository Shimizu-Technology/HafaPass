# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrganizationTeam do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:owner) { create(:user, :organizer, email: "owner@example.com") }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:organization) { profile.organization }

  it "emails the invitation through the durable delivery pipeline and keeps a copy link" do
    membership, token = described_class.invite!(organization: organization, email: " New@Example.com ",
      role: "finance", actor: owner)

    expect(token).to be_present
    delivery = MessageDelivery.find_by!(organization_membership: membership)
    expect(delivery).to have_attributes(template: "organization_invitation", recipient: "new@example.com",
      idempotency_key: "organization-invitation/#{membership.id}/v#{membership.invitation_version}")
    expect(MessageDeliveryJob).to have_been_enqueued.with(delivery.id)
    expect(membership.invitation_status).to eq("pending")
  end

  it "renders the email with the accept link, role description and expiry" do
    membership, = described_class.invite!(organization: organization, email: "new@example.com", role: "marketer",
      actor: owner)
    delivery = MessageDelivery.find_by!(organization_membership: membership)
    delivery.preparing_outbound_payload = true
    payload = EmailService.send_organization_invitation(membership, delivery: delivery)

    expect(payload["to"]).to eq("new@example.com")
    expect(payload["subject"]).to include(organization.name)
    expect(payload["html"]).to include("Marketer", "event pages, promo codes and messages",
      "/organization-invitations/accept?token=")
  end

  it "resends with a new link and cancels the stale unsent email" do
    membership, first_token = described_class.invite!(organization: organization, email: "new@example.com",
      role: "finance", actor: owner)
    stale = MessageDelivery.find_by!(organization_membership: membership)

    travel 61.seconds
    second_token = described_class.resend!(membership: membership, actor: owner)

    expect(second_token).not_to eq(first_token)
    expect(MessageDelivery.where(organization_membership: membership).count).to eq(2)
    MessageDeliveryJob.perform_now(stale.id)
    expect(stale.reload).to be_cancelled
    expect(SignedCredential.verify(namespace: "organization_invitation", token: first_token)["version"])
      .not_to eq(membership.reload.invitation_version)
  end

  it "never sends a revoked invitation" do
    membership, = described_class.invite!(organization: organization, email: "new@example.com", role: "finance",
      actor: owner)
    delivery = MessageDelivery.find_by!(organization_membership: membership)
    described_class.revoke!(membership: membership, actor: owner)

    MessageDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload).to be_cancelled
    expect(membership.reload.invitation_status).to eq("revoked")
  end

  it "refuses owner invitations unless explicitly allowed" do
    expect { described_class.invite!(organization: organization, email: "x@example.com", role: "owner", actor: owner) }
      .to raise_error(described_class::TeamError)
  end

  it "removes a revoked member's event assignments" do
    staff = create(:user)
    membership = create(:organization_membership, organization: organization, user: staff, role: :scanner)
    event = create(:event, organizer_profile: profile)
    assignment = create(:event_staff_assignment, organization: organization, event: event, user: staff)

    described_class.revoke!(membership: membership, actor: owner)

    expect(assignment.reload).to be_status_revoked
  end

  it "rolls back membership and assignment revocation if its audit cannot be saved" do
    membership = create(:organization_membership, organization: organization, role: :scanner)
    event = create(:event, organizer_profile: profile)
    assignment = create(:event_staff_assignment, organization: organization, event: event, user: membership.user)
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "organization.membership_revoked"))
      .and_raise(AuditLogger::WriteError)

    expect { described_class.revoke!(membership: membership, actor: owner) }.to raise_error(AuditLogger::WriteError)
    expect(membership.reload).to be_status_active
    expect(assignment.reload).to be_status_active
    expect(AuditLog.where(auditable: assignment, action: "event_staff.revoked")).not_to exist
  end

  it "rolls back the invitation and quota dispatch if its audit cannot be saved" do
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "organization.invitation_created"))
      .and_raise(AuditLogger::WriteError)
    expect do
      described_class.invite!(organization: organization, email: "atomic@example.com", role: "scanner", actor: owner)
    end.to raise_error(AuditLogger::WriteError)
    expect(organization.organization_memberships.where(invited_email: "atomic@example.com")).not_to exist
    expect(OrganizationInvitationDispatch.where(organization: organization)).not_to exist
  end

  describe ".transfer_ownership!" do
    let(:manager) { create(:user, email: "manager@example.com") }
    let!(:manager_membership) { create(:organization_membership, organization: organization, user: manager, role: :manager) }

    it "hands ownership over, demotes the previous owner and audits it" do
      described_class.transfer_ownership!(organization: organization, to_membership: manager_membership, actor: owner)

      expect(manager_membership.reload).to be_owner
      expect(organization.organization_memberships.find_by(user: owner)).to be_manager
      expect(profile.reload.user).to eq(manager)
      audit = AuditLog.find_by!(action: "organization.ownership_transferred", auditable: organization)
      expect(audit.actor_user).to eq(owner)
      expect(OrganizationAuthorization.allowed?(user: owner, organization: organization, permission: :payout)).to be(false)
      expect(OrganizationAuthorization.allowed?(user: manager, organization: organization, permission: :payout)).to be(true)
    end

    it "refuses pending invitees and non-owners" do
      pending = create(:organization_membership, organization: organization, user: nil, invited_email: "p@example.com",
        status: :invited, accepted_at: nil, role: :finance)
      expect { described_class.transfer_ownership!(organization: organization, to_membership: pending, actor: owner) }
        .to raise_error(described_class::TeamError)
      expect do
        described_class.transfer_ownership!(organization: organization, to_membership: manager_membership, actor: manager)
      end.to raise_error(described_class::TeamError, /Only the owner/)
    end
  end

  it "preserves event staff invite and resend access for event managers" do
    manager = create(:user)
    create(:organization_membership, organization: organization, user: manager, role: :scanner)
    event = create(:event, organizer_profile: profile)
    create(:event_staff_assignment, organization: organization, event: event, user: manager, role: :manager)
    membership, = described_class.invite!(organization: organization, email: "door@example.com", role: :scanner,
      actor: manager, event_assignment: { event: event, role: :scanner })
    travel 61.seconds
    expect { described_class.resend!(membership: membership, actor: manager, event: event) }.not_to raise_error
    travel 61.seconds
    expect { described_class.resend!(membership: membership, actor: manager) }
      .to raise_error(described_class::TeamError, /permission/)
  end
end
