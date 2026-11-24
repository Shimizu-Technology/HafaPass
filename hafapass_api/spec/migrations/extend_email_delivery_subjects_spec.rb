require "rails_helper"
require Rails.root.join("db/migrate/20261124140200_extend_email_delivery_subjects")

RSpec.describe ExtendEmailDeliverySubjects do
  it "restores the old subject constraint without validating legacy platform rows on rollback" do
    migration = described_class.new
    expect(migration).to receive(:add_check_constraint).with(:message_deliveries, a_string_including("privacy_request_id IS NOT NULL"), name: "message_deliveries_subject_present_with_privacy", validate: false)
    expect(migration).to receive(:remove_check_constraint).with(:message_deliveries, name: "message_deliveries_subject_present_email_base")
    expect(migration).to receive(:remove_column).with(:audience_mailings, :recipient_emails)
    expect { migration.down }.not_to raise_error
  end
end
