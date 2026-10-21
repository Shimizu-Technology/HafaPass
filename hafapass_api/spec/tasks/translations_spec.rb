require "rails_helper"
require "rake"

RSpec.describe "translations:backfill" do
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("translations:backfill")
    with_gt_credentials
    allow_any_instance_of(TranslateRecordJob).to receive(:perform) do |_, class_name, id, *_args|
      class_name.constantize.find(id).update_column(:translation_status, "translated")
    end
  end

  it "recovers stale pending records but leaves recently queued records alone" do
    stale = create(:event, :published)
    recent = create(:event, :published)
    stale_type = create(:ticket_type, event: stale)
    [stale, stale_type].each do |record|
      pending_since = record.has_attribute?(:translation_requested_at) ? :translation_requested_at : :updated_at
      record.update_columns(translation_status: "pending", pending_since => Translatable::STUCK_PENDING_AFTER.ago - 1.minute)
    end
    recent.update_columns(translation_status: "pending", translation_requested_at: 1.minute.ago)

    expect { Rake::Task["translations:backfill"].execute }.to output(/Done/).to_stdout

    expect(stale.reload.translation_status).to eq("translated")
    expect(stale_type.reload.translation_status).to eq("translated")
    expect(recent.reload.translation_status).to eq("pending")
  end
end
