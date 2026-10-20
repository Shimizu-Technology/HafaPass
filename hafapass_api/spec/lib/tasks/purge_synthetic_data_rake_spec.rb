require "rails_helper"
require "rake"

RSpec.describe "hafapass:purge_synthetic_data" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("hafapass:purge_synthetic_data")
  end

  let(:task) { Rake::Task["hafapass:purge_synthetic_data"] }
  let!(:kept) { create(:user, :admin, email: "ops@hafapass.example") }
  let!(:other) { create(:user) }

  around do |example|
    original = ENV.to_h.slice("CONFIRM", "KEEP_USER_EMAILS")
    example.run
  ensure
    %w[CONFIRM KEEP_USER_EMAILS].each { |key| original.key?(key) ? ENV[key] = original[key] : ENV.delete(key) }
  end

  it "passes CONFIRM and KEEP_USER_EMAILS through and purges" do
    ENV["CONFIRM"] = "PURGE_SYNTHETIC_DATA"
    ENV["KEEP_USER_EMAILS"] = "ops@hafapass.example"
    task.reenable

    expect { task.invoke }.to output(/Deleted 1 users/).to_stdout
    expect(User.pluck(:id)).to eq([kept.id])
    expect(AuditLog.sole.action).to eq("operations.synthetic_data_purged")
  end

  it "aborts without changing anything when CONFIRM is missing" do
    ENV.delete("CONFIRM")
    ENV["KEEP_USER_EMAILS"] = "ops@hafapass.example"
    task.reenable

    expect { task.invoke }.to raise_error(SystemExit).and output(/Refused: Set CONFIRM=PURGE_SYNTHETIC_DATA.*Nothing was changed/).to_stderr
    expect(User.count).to eq(2)
  end
end
