require "rails_helper"
require Rails.root.join("db/migrate/20261021200200_add_invitation_subjects_to_message_deliveries")

RSpec.describe AddInvitationSubjectsToMessageDeliveries do
  around { |example| ActiveRecord::Migration.suppress_messages(&example) }

  it "refuses to roll back while invitation-only email deliveries exist" do
    membership = create(:organization_membership, user: nil, invited_email: "x@example.com", status: :invited,
      accepted_at: nil, role: :finance)
    MessageDelivery.create!(organization_membership: membership, channel: "email", template: "organization_invitation",
      recipient: "x@example.com", provider: "simulated", status: :queued)

    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration, /Invitation-only/)
  end
end
