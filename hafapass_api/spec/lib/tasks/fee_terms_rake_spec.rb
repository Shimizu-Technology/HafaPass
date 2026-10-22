require "rails_helper"
require "rake"

RSpec.describe "hafapass:adopt_launch_fee_terms" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("hafapass:adopt_launch_fee_terms")
  end

  let(:task) { Rake::Task["hafapass:adopt_launch_fee_terms"] }

  def run_task
    task.reenable
    expect { task.invoke }.to output.to_stdout
  end

  it "moves untouched 3% + 50 cent defaults to the launch fee once, with an audit record" do
    SiteSetting.instance.update_columns(service_fee_percent: 3.0, service_fee_flat_cents: 50)

    run_task
    run_task

    expect(SiteSetting.instance.reload).to have_attributes(service_fee_percent: 5.0, service_fee_flat_cents: 100)
    audits = AuditLog.where(action: "site_settings.fee_terms_updated")
    expect(audits.count).to eq(1)
    expect(audits.first).to have_attributes(
      before_data: { "service_fee_percent" => "3.0", "service_fee_flat_cents" => "50" },
      after_data: { "service_fee_percent" => "5.0", "service_fee_flat_cents" => "100" },
      metadata: { "source" => "hafapass:adopt_launch_fee_terms" }
    )
  end

  it "never overwrites an admin-chosen fee" do
    SiteSetting.instance.update_columns(service_fee_percent: 3.0, service_fee_flat_cents: 75)

    expect(SiteSetting.adopt_launch_fee_terms!).to eq(:custom)
    run_task

    expect(SiteSetting.instance.reload).to have_attributes(service_fee_percent: 3.0, service_fee_flat_cents: 75)
    expect(AuditLog.where(action: "site_settings.fee_terms_updated")).to be_empty
  end

  it "reports already-adopted terms without writing" do
    expect(SiteSetting.adopt_launch_fee_terms!).to eq(:already_adopted)
    expect(AuditLog.where(action: "site_settings.fee_terms_updated")).to be_empty
  end
end
