require "rails_helper"
require Rails.root.join("db/migrate/20261021200000_separate_invitation_expiry_from_membership_expiry")

RSpec.describe SeparateInvitationExpiryFromMembershipExpiry do
  let(:migration) { described_class.new }
  let(:organization) { create(:organization) }
  let(:invited_at) { Time.zone.parse("2026-09-01 10:00:00") }

  def column?(name)
    OrganizationMembership.connection.column_exists?(:organization_memberships, name)
  end

  around { |example| ActiveRecord::Migration.suppress_messages(&example) }

  after do
    unless column?(:invitation_expires_at)
      migration.up
      OrganizationMembership.reset_column_information
    end
  end

  it "restores access cut off by the stale invite lifetime and keeps deliberate expiries" do
    bug_victim = create(:organization_membership, organization: organization, role: :finance,
      invited_at: invited_at, expires_at: invited_at + 7.days, accepted_at: invited_at + 1.day)
    deliberate = create(:organization_membership, organization: organization, role: :scanner,
      invited_at: invited_at, expires_at: invited_at + 30.days, accepted_at: invited_at + 1.day)
    open_invite = create(:organization_membership, organization: organization, role: :marketer, user: nil,
      invited_email: "open@example.com", status: :invited, accepted_at: nil,
      invited_at: invited_at, expires_at: invited_at + 7.days)

    migration.down
    OrganizationMembership.reset_column_information
    expect(column?(:invitation_expires_at)).to be(false)
    expect(open_invite.reload.expires_at).to eq(invited_at + 7.days)

    migration.up
    OrganizationMembership.reset_column_information

    expect(bug_victim.reload.expires_at).to be_nil
    expect(bug_victim).to be_effective
    expect(deliberate.reload.expires_at).to eq(invited_at + 30.days)
    expect(open_invite.reload).to have_attributes(expires_at: nil, invitation_expires_at: invited_at + 7.days)
  end
end
