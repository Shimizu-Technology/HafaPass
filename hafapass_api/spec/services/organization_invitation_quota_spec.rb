# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrganizationInvitationQuota do
  include ActiveSupport::Testing::TimeHelpers
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:actor) { profile.user }

  def invite(email = "guest@example.com", org: organization)
    OrganizationTeam.invite!(organization: org, actor: actor, email: email, role: "scanner", deliver: false)
  end

  it "normalizes recipient cooldown and does not rotate links or enqueue on refusal" do
    membership, token = invite(" Guest+Door@Example.com ")
    expect do
      OrganizationTeam.resend!(membership: membership, actor: actor)
    end.to raise_error(OrganizationTeam::TeamError, /Wait a minute/)
    expect(OrganizationInvitation.token_for(membership.reload)).to eq(token)
    expect(OrganizationInvitationDispatch.count).to eq(1)
    travel 61.seconds do
      expect(OrganizationTeam.resend!(membership: membership, actor: actor)).not_to eq(token)
    end
  end

  it "budgets each actor across organizations" do
    stub_const("OrganizationInvitationQuota::ACTOR_HOURLY_LIMIT", 1)
    invite
    other = create(:organization)
    expect { invite("other@example.com", org: other) }.to raise_error(OrganizationTeam::TeamError, /past hour/)
    expect(other.organization_memberships).to be_empty
  end

  it "budgets an organization across actors and rolls back failed reservations" do
    stub_const("OrganizationInvitationQuota::ORGANIZATION_HOURLY_LIMIT", 1)
    expect { invite("invalid") }.to raise_error(OrganizationTeam::TeamError)
    expect(OrganizationInvitationDispatch.count).to eq(0)
    invite
    expect do
      OrganizationTeam.invite!(organization: organization, actor: create(:user, :admin), email: "two@example.com", role: "scanner")
    end.to raise_error(OrganizationTeam::TeamError, /This team/)
    travel 1.hour + 1.second do
      expect { invite("later@example.com") }.to change(OrganizationInvitationDispatch, :count).by(1)
    end
  end
end
