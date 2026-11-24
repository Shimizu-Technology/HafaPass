require "rails_helper"
require Rails.root.join("db/migrate/20261124140200_extend_email_delivery_subjects")

RSpec.describe ExtendEmailDeliverySubjects do
  it "restores the old constraint only when every delivery has a legacy subject" do
    migration = described_class.new
    expect(migration).to receive(:select_value).with(a_string_including("WHERE order_id IS NULL")).and_return(nil)
    expect(migration).to receive(:add_check_constraint).with(:message_deliveries, a_string_including("privacy_request_id IS NOT NULL"), name: "message_deliveries_subject_present_with_privacy", validate: false)
    expect(migration).to receive(:remove_check_constraint).with(:message_deliveries, name: "message_deliveries_subject_present_email_base")
    expect(migration).to receive(:remove_column).with(:audience_mailings, :recipient_emails)
    expect { migration.down }.not_to raise_error
  end
  it "N4: refuses rollback before changing schema when email-base-only rows exist" do
    PlatformSubscriber.create!(email: "rollback@example.test", source: "footer").message_deliveries.create!(
      channel: "email", template: "platform_confirmation", recipient: "rollback@example.test", provider: "simulated")
    migration = described_class.new
    expect(migration).not_to receive(:add_check_constraint)
    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /Reconcile email-base-only/)
  end
end
