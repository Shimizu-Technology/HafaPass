require "rails_helper"

RSpec.describe "Deletion path inventory" do
  # Every destructive call in app/jobs and app/services is classified here.
  # A new call, even in an already reviewed file, must add a guard or a reason.
  PATHS = {
    "jobs/runtime_retention_job.rb" => [
      [/RuntimeThrottleBucket.*\.delete_all/, 1, "exempt: expired rate-limit bucket"],
      [/RuntimeExecution.*\.delete_all/, 1, "exempt: expired runtime metrics"]
    ],
    "jobs/data_retention_purge_job.rb" => [
      [/record\.destroy!/, 1, "guarded under record lock by RetentionGuard"]
    ],
    "jobs/purge_marketplace_analytics_job.rb" => [
      [/event\.destroy!/, 1, "guarded under event lock by RetentionGuard"]
    ],
    "jobs/organizer_sales_export_job.rb" => [
      [/S3Service\.delete_private_export!/, 1, "guarded by retention advisory lock and RetentionGuard"]
    ],
    "jobs/organizer_sales_export_cleanup_job.rb" => [
      [/S3Service\.delete_private_export!/, 1, "guarded by row and retention advisory locks"]
    ],
    "jobs/organizer_sales_export_orphan_sweep_job.rb" => [
      [/S3Service\.delete_private_export!/, 1, "guarded by per-object hold recheck and advisory lock"]
    ],
    "jobs/translate_record_job.rb" => [
      [/merged\.delete\(/, 1, "exempt: removes an in-memory translation key"]
    ],
    "services/data_retention.rb" => [
      [/child\.delete\b/, 1, "guarded under child lock by RetentionGuard"],
      [/order\.delete\b/, 1, "guarded under order lock by RetentionGuard"]
    ],
    "services/privacy_request_processor.rb" => [
      [/pass\.destroy!/, 1, "guarded under pass lock by RetentionGuard"],
      [/record\.delete\b/, 1, "guarded under record lock by RetentionGuard"],
      [/S3Service\.delete_upload!/, 2, "guarded by upload row and retention advisory locks"],
      [/upload\.destroy!/, 1, "guarded under upload row and retention advisory locks"]
    ],
    "services/s3_service.rb" => [
      [/\.delete_object\b/, 3, "storage primitive: callers own guard; pending upload has lifecycle TTL"]
    ],
    "services/seating/configuration_activator.rb" => [
      [/event_seats\.destroy_all/, 1, "exempt: unsold draft seats after history check"],
      [/existing\.destroy!/, 1, "exempt: unsold draft configuration after history check"]
    ],
    "services/wallet/pass_sync.rb" => [
      [/apple_wallet_registrations.*\.delete_all/, 1, "exempt: provider confirmed dead push tokens"]
    ],
    "services/commerce/refund_creator.rb" => [
      [/@cash_return_evidence\.delete/, 1, "exempt: removes an in-memory field"]
    ],
    "services/connected_accounts/manager.rb" => [
      [/values\.delete/, 2, "exempt: removes in-memory form fields"],
      [/\.to_s\.delete/, 1, "exempt: normalizes an in-memory bank account string"],
      [/allowed\.delete/, 1, "exempt: removes in-memory form field"]
    ],
    "services/organizer_tax_information_updater.rb" => [
      [/values\.delete/, 1, "exempt: removes in-memory form field"]
    ],
    "services/ticket_pdf_generator.rb" => [
      [/tempfile&\.unlink/, 1, "exempt: removes a task-owned temporary PDF file"]
    ],
    "services/operations/postgres_throttle_store.rb" => [
      [/RuntimeThrottleBucket.*\.delete_all/, 2, "exempt: expired or reset rate-limit buckets"]
    ],
    "services/operations/synthetic_data_purge.rb" => [
      [/statement\("TRUNCATE"/, 1, "exempt: explicit pre-launch synthetic-only reset"],
      [/User\.where.*\.delete_all/, 1, "exempt: explicit pre-launch synthetic-only reset"],
      [/connection\.delete\(/, 2, "exempt: explicit pre-launch synthetic-only reset"]
    ]
  }.freeze

  it "accounts for every row or S3 deletion call with a guard or explicit exemption" do
    candidate = /\.(?:delete(?:_all|_object|_upload!|_private_export!)?|destroy(?:_all|!)?|unlink)(?![[:alnum:]_])|statement\("TRUNCATE"/
    actual = Rails.root.glob("app/{jobs,services}/**/*.rb").flat_map do |file|
      relative = file.relative_path_from(Rails.root.join("app")).to_s
      File.readlines(file).filter_map do |line|
        [relative, line.strip] if line.match?(candidate) && !line.lstrip.start_with?("#")
      end
    end
    expected = PATHS.flat_map do |file, entries|
      entries.flat_map do |pattern, count, reason|
        expect(reason).to match(/\A(?:guarded|exempt|storage primitive)/)
        matches = actual.select { |path, line| path == file && line.match?(pattern) }
        expect(matches.size).to eq(count), "#{file} #{pattern} changed; review its deletion guard"
        matches
      end
    end
    expect(actual.sort).to eq(expected.sort)
  end
end
