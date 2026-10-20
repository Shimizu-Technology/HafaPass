require "rails_helper"
require Rails.root.join("db/migrate/20261020193000_move_support_email_to_site_settings")

RSpec.describe MoveSupportEmailToSiteSettings do
  let(:migration) { described_class.new }
  let(:setting) { SiteSetting.instance }

  def platform_email_default
    SiteSetting.connection.columns(:site_settings).find { |column| column.name == "platform_email" }.default
  end

  after { migration.up if platform_email_default.present? }

  it "fills a blank or untouched legacy address and drops the hardcoded column default" do
    [nil, "", "tickets@hafapass.com"].each do |value|
      migration.down
      expect(platform_email_default).to eq("tickets@hafapass.com")
      setting.update_columns(platform_email: value)

      migration.up

      expect(setting.reload.platform_email).to eq("shimizutechnology@gmail.com")
      expect(platform_email_default).to be_nil
    end
  end

  it "keeps an admin-chosen address on the way up and down" do
    setting.update_columns(platform_email: "help@example.test")

    migration.up
    expect(setting.reload.platform_email).to eq("help@example.test")
    migration.down
    expect(setting.reload.platform_email).to eq("help@example.test")
  end
end
