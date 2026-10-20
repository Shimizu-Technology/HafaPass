require "rails_helper"
require Rails.root.join("db/migrate/20261020120000_adopt_all_in_buyer_fee_defaults")

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

  it "moves only the untouched 3% + 50 cent pair to the all-in default with the platform bearer" do
    SiteSetting.update_all(service_fee_percent: 3.0, service_fee_flat_cents: 50)

    migrate_up

    expect(row).to include("service_fee_percent" => BigDecimal("5.0"), "service_fee_flat_cents" => 100,
      "processing_fee_bearer" => "platform", "payout_schedule_text" => "within 3 business days after your event")
    expect([column_default("service_fee_percent"), column_default("service_fee_flat_cents")]).to eq(["5.0", "100"])
  end

  [[4.0, 50], [3.0, 75], [0.0, 0]].each do |percent, flat|
    it "keeps an admin-chosen #{percent}% + #{flat} cent fee" do
      SiteSetting.update_all(service_fee_percent: percent, service_fee_flat_cents: flat)

      migrate_up

      expect(row).to include("service_fee_percent" => BigDecimal(percent.to_s), "service_fee_flat_cents" => flat,
        "processing_fee_bearer" => "platform")
    end
  end

  it "restores only column defaults on rollback and keeps a fee the admin may have set" do
    migrate_up
    SiteSetting.update_all(service_fee_percent: 6.5, service_fee_flat_cents: 125)

    migration.down
    SiteSetting.reset_column_information

    expect(row).to include("service_fee_percent" => BigDecimal("6.5"), "service_fee_flat_cents" => 125)
    expect([column_default("service_fee_percent"), column_default("service_fee_flat_cents")]).to eq(["3.0", "50"])
    expect(row).not_to have_key("processing_fee_bearer")
  end

  it "keeps the all-in values on rollback rather than guessing they were untouched" do
    migrate_up

    migration.down
    SiteSetting.reset_column_information

    expect(row).to include("service_fee_percent" => BigDecimal("5.0"), "service_fee_flat_cents" => 100)
  end
end
