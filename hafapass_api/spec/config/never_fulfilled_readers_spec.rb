# frozen_string_literal: true

require "rails_helper"

# The never-fulfilled reader register (design §8.1, §8.10.12): a new money
# reader cannot be added without saying how it treats a classified capture.
RSpec.describe "Never-fulfilled reader register" do
  MONEY_STATE = /partially_refunded|:refunded|"refunded"|excluding_test_payments/
  CLASSIFIED_RULE = /excluding_never_fulfilled|never_fulfilled_at|ClassifiedOrganizerView|ClassifiedPaymentFinance|UnfulfilledCapture|\.on_sale\b|sale_refunds|never_fulfilled/
  TREATMENTS = %w[classified_rule shared_reader writer_boundary platform_only not_money].freeze

  let(:register) { YAML.safe_load_file(Rails.root.join("config/never_fulfilled_readers.yml")).fetch("readers") }
  let(:readers) do
    Dir[Rails.root.join("app/**/*.rb")].map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
      .select { |path| File.read(Rails.root.join(path)).match?(MONEY_STATE) }.sort
  end

  it "lists every money-state reader under app/, and nothing else" do
    expect(readers - register.keys).to eq([]), "Register these readers in config/never_fulfilled_readers.yml"
    expect(register.keys - readers).to eq([]), "These registered files no longer read money states"
  end

  it "gives each a known treatment and a note" do
    register.each do |path, entry|
      expect(TREATMENTS).to include(entry["treatment"]), path
      expect(entry["note"].to_s).to be_present, path
    end
  end

  it "keeps every classified_rule reader on the shared rule" do
    register.select { |_path, entry| entry["treatment"] == "classified_rule" }.each_key do |path|
      expect(File.read(Rails.root.join(path))).to match(CLASSIFIED_RULE), path
    end
  end
end
