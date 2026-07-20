# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrganizationAuthorization do
  ALL_PERMISSIONS = described_class::PERMISSIONS.values.flatten.uniq.freeze

  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, organizer_profile: profile) }

  described_class::PERMISSIONS.each do |role, expected_permissions|
    it "enforces the #{role} role permission matrix" do
      user = create(:user)
      create(:organization_membership, organization: organization, user: user, role: role)
      if described_class::ASSIGNMENT_REQUIRED_ROLES.include?(role.to_s)
        create(:event_staff_assignment, organization: organization, event: event, user: user, role: role)
      end

      ALL_PERMISSIONS.each do |permission|
        expected = expected_permissions.include?(permission)
        expect(described_class.allowed?(user: user, organization: organization, permission: permission, event: event))
          .to eq(expected), "expected #{role} #{permission} to be #{expected}"
      end
    end
  end

  it "limits assignment-based roles to their assigned events" do
    user = create(:user)
    membership = create(:organization_membership, organization: organization, user: user, role: :scanner)
    assigned_event = event
    other_event = create(:event, organizer_profile: profile)
    create(:event_staff_assignment, organization: organization, event: assigned_event, user: user, role: :scanner)

    expect(described_class.allowed?(user: user, organization: organization, permission: :scan, event: assigned_event)).to be(true)
    expect(described_class.allowed?(user: user, organization: organization, permission: :scan, event: other_event)).to be(false)
    expect(described_class.accessible_events(user: user, organization: organization)).to contain_exactly(assigned_event)

    membership.update!(expires_at: 1.minute.ago)
    expect(described_class.accessible_events(user: user, organization: organization)).to be_empty
  end

  it "never authorizes an event belonging to another organization" do
    user = create(:user)
    create(:organization_membership, organization: organization, user: user, role: :owner)
    other_event = create(:event)

    expect(described_class.allowed?(user: user, organization: organization, permission: :manage_events,
      event: other_event)).to be(false)
  end
end
