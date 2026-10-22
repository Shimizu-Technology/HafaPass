require "rails_helper"

RSpec.describe "Retention migration safety" do
  it "builds new indexes outside DDL transactions and validates replacement constraints separately" do
    %w[20261022110000_create_organizer_sales_export_requests.rb
      20261022150000_add_data_retention_controls.rb].each do |filename|
      source = Rails.root.join("db/migrate", filename).read
      expect(source).to include("disable_ddl_transaction!")
      source.scan(/add_index[^\n]*/).each do |index_statement|
        expect(index_statement).to include("algorithm: :concurrently")
      end
    end
    controls = Rails.root.join("db/migrate/20261022150000_add_data_retention_controls.rb").read
    expect(controls).to include('name: "message_deliveries_subject_present_with_privacy", validate: false')
    expect(controls).to include('validate_check_constraint :message_deliveries, name: "message_deliveries_subject_present_with_privacy"')
    expect(controls.index("validate_check_constraint")).to be < controls.index('remove_check_constraint :message_deliveries')
    expect(ActiveRecord::Base.connection.check_constraints(:message_deliveries).map(&:name))
      .to include("message_deliveries_subject_present_with_privacy")
  end

  it "creates every new index on an existing table concurrently in a separate transaction" do
    migrations = Dir[Rails.root.join("db/migrate/2026102215*.rb")]
    expect(migrations.map { |path| File.basename(path) }).to include(
      "20261022150000_add_data_retention_controls.rb", "20261022151000_add_retention_anonymized_at.rb",
      "20261022152000_add_retention_markers_to_related_records.rb",
      "20261022153000_add_financial_retention_markers.rb")
    migrations.each do |path|
      source = File.read(path)
      next unless source.match?(/add_index\s+/)

      expect(source).to include("disable_ddl_transaction!"), path
      source.lines.each_with_index.filter_map do |line, index|
        source.lines[index, 3].join if line.match?(/\badd_index\s+/)
      end.each do |statement|
        expect(statement).to include("algorithm: :concurrently"), "#{path}: #{statement}"
      end
    end
    expect(ActiveRecord::Base.connection.indexes(:orders).map(&:name))
      .to include("index_orders_on_retention_anonymized_at")
  end
end
