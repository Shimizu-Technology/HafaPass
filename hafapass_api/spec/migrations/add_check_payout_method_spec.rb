require "rails_helper"
require Rails.root.join("db/migrate/20261021200300_add_check_payout_method")

RSpec.describe AddCheckPayoutMethod do
  around { |example| ActiveRecord::Migration.suppress_messages(&example) }

  it "refuses to roll back while check payees or owner-less organizer profiles exist" do
    create(:connected_account, provider: "check", provider_account_id: nil,
      payout_details: { "payee_name" => "Ambros", "delivery_method" => "pickup" })

    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration, /Check payout accounts/)
    expect(ConnectedAccount.connection.column_exists?(:connected_accounts, :payout_details)).to be(true)
  end
end
