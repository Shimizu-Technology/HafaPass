require "rails_helper"
require Rails.root.join("db/migrate/20261020200000_adopt_all_in_buyer_fee_defaults")
require Rails.root.join("db/migrate/20261020200100_snapshot_processing_fee_bearer_on_orders")

RSpec.describe AdoptAllInBuyerFeeDefaults do
  let(:migration) { described_class.new }

  around do |example|
    SiteSetting.instance
    ActiveRecord::Migration.suppress_messages do
      migration.down
      SiteSetting.reset_column_information
      example.run
    ensure
      migration.up if SiteSetting.connection.columns(:site_settings).none? { |column| column.name == "processing_fee_bearer" }
      SiteSetting.reset_column_information
    end
  end

  def column_default(name)
    SiteSetting.connection.columns(:site_settings).find { |column| column.name == name }.default
  end

  def row
    SiteSetting.connection.select_one("SELECT * FROM site_settings LIMIT 1")
  end

  def migrate_up
    migration.up
    SiteSetting.reset_column_information
  end

  # Old code may still be serving checkouts while the migration runs, so the
  # fee values move only through the audited post-deploy task.
  [[3.0, 50], [4.0, 50], [0.0, 0]].each do |percent, flat|
    it "adds the bearer and payout schedule without changing a #{percent}% + #{flat} cent fee" do
      SiteSetting.update_all(service_fee_percent: percent, service_fee_flat_cents: flat)

      migrate_up

      expect(row).to include("service_fee_percent" => BigDecimal(percent.to_s), "service_fee_flat_cents" => flat,
        "processing_fee_bearer" => "platform", "payout_schedule_text" => "within 3 business days after your event")
      expect([column_default("service_fee_percent"), column_default("service_fee_flat_cents")]).to eq(["5.0", "100"])
    end
  end

  it "restores only column defaults on rollback and keeps row values" do
    migrate_up
    SiteSetting.update_all(service_fee_percent: 6.5, service_fee_flat_cents: 125)

    migration.down
    SiteSetting.reset_column_information

    expect(row).to include("service_fee_percent" => BigDecimal("6.5"), "service_fee_flat_cents" => 125)
    expect([column_default("service_fee_percent"), column_default("service_fee_flat_cents")]).to eq(["3.0", "50"])
    expect(row).not_to have_key("processing_fee_bearer")
  end
end

RSpec.describe SnapshotProcessingFeeBearerOnOrders do
  it "refuses to roll back once any order has a recorded bearer" do
    create(:order, processing_fee_bearer_snapshot: "platform")

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.down } }
      .to raise_error(ActiveRecord::IrreversibleMigration, /restate their settlements/)
    expect(Order.connection.column_exists?(:orders, :processing_fee_bearer_snapshot)).to be(true)
  end

  it "rolls back and forward cleanly while every order is legacy" do
    create(:order)

    ActiveRecord::Migration.suppress_messages do
      described_class.new.down
      expect(Order.connection.column_exists?(:orders, :processing_fee_bearer_snapshot)).to be(false)
      described_class.new.up
    end
    Order.reset_column_information
    expect(Order.connection.column_exists?(:orders, :processing_fee_bearer_snapshot)).to be(true)
  end
end
