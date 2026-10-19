require "rails_helper"
require Rails.root.join("db/migrate/20261020090100_brand_default_platform_name")

RSpec.describe BrandDefaultPlatformName do
  let(:migration) { described_class.new }

  def platform_name_default
    SiteSetting.connection.columns(:site_settings).find { |column| column.name == "platform_name" }.default
  end

  it "rebrands only the untouched default name and the column default" do
    setting = SiteSetting.instance
    setting.update_columns(platform_name: "HafaPass")
    migration.down
    expect(platform_name_default).to eq("HafaPass")

    migration.up
    expect(setting.reload.platform_name).to eq("HåfaPass")
    expect(platform_name_default).to eq("HåfaPass")

    setting.update_columns(platform_name: "Island Tickets")
    migration.up
    expect(setting.reload.platform_name).to eq("Island Tickets")
  end
end
