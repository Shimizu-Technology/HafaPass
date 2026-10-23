# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Serialized organization ownership" do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:successor) { create(:organization_membership, organization: organization, role: :manager) }

  %i[revoke change_role].each do |mutation|
    it "rechecks a stale target after transfer before #{mutation}" do
      stale = OrganizationMembership.find(successor.id)
      OrganizationTeam.transfer_ownership!(organization: organization, to_membership: successor, actor: owner)
      expect(stale).to be_manager
      options = { membership: stale, actor: create(:user, :admin) }
      options[:role] = "scanner" if mutation == :change_role
      expect { OrganizationTeam.public_send("#{mutation}!", **options) }.to raise_error(OrganizationTeam::TeamError, /ownership|Ownership/)
      expect(organization.organization_memberships.effective.where(role: :owner).pluck(:id)).to eq([successor.id])
      expect(successor.reload).to be_status_active
    end
  end

  it "rechecks active owner authority before a competing transfer" do
    next_person = create(:organization_membership, organization: organization, role: :finance)
    OrganizationTeam.transfer_ownership!(organization: organization, to_membership: successor, actor: owner)
    expect do
      OrganizationTeam.transfer_ownership!(organization: organization, to_membership: next_person, actor: owner)
    end.to raise_error(OrganizationTeam::TeamError, /Only the owner/)
    expect(organization.organization_memberships.effective.where(role: :owner).count).to eq(1)
  end
end
