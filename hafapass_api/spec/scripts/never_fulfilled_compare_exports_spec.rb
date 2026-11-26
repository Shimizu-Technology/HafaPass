# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

# script/never_fulfilled/compare_exports.rb: the A2 release's like-for-like
# CSV comparison (docs/NEVER_FULFILLED_RELEASE.md "A2 release").
RSpec.describe "script/never_fulfilled/compare_exports.rb" do
  def run(*args)
    Open3.capture2e("ruby", Rails.root.join("script/never_fulfilled/compare_exports.rb").to_s, *args)
  end

  it "compares pre-existing columns byte for byte, lists appended ones, and fails only on unexpected changes" do
    Dir.mktmpdir do |dir|
      baseline = File.join(dir, "baseline").tap { |path| Dir.mkdir(path) }
      candidate = File.join(dir, "candidate").tap { |path| Dir.mkdir(path) }
      File.write(File.join(baseline, "cpa-2027-01.csv"), "row_type,organization_id,event_id,gross\nevent,1,10,5.00\nevent,1,11,3.00\n")
      File.write(File.join(candidate, "cpa-2027-01.csv"),
        "row_type,organization_id,event_id,gross,closing_buyer_owed_gross\nevent,1,10,5.00,0.00\nevent,1,11,2.00,1.36\n")

      output, status = run(baseline, candidate)
      expect(status.exitstatus).to eq(1)
      expect(output).to include('event/1/11 CHANGED: gross "3.00"->"2.00"', "event/1/11 appended: closing_buyer_owed_gross=1.36",
        "1/2 rows byte-identical in the 4 pre-existing columns", "unexpected_differences=1")

      expected = File.join(dir, "expected.txt")
      File.write(expected, "# rehearsal diff\ncpa-2027-01.csv event/1/11\n")
      output, status = run(baseline, candidate, expected)
      expect(status.exitstatus).to eq(0)
      expect(output).to include("CHANGED (expected)", "unexpected_differences=0")

      File.write(File.join(candidate, "cpa-2027-01.csv"), "organization_id,row_type,event_id,gross\n1,event,10,5.00\n")
      output, status = run(baseline, candidate, expected)
      expect(status.exitstatus).to eq(1)
      expect(output).to include("HEADER CHANGED")
    end
  end

  # CodeRabbit 4703321699 and 4703321701: no false success.
  it "refuses a missing or empty baseline instead of reporting zero differences" do
    Dir.mktmpdir do |dir|
      candidate = File.join(dir, "candidate").tap { |path| Dir.mkdir(path) }
      File.write(File.join(candidate, "cpa-2027-01.csv"), "row_type,organization_id,event_id,gross\nevent,1,10,5.00\n")

      output, status = run(File.join(dir, "mistyped"), candidate)
      expect(status.exitstatus).to eq(2)
      expect(output).to include("does not exist", "unexpected_differences=unusable_input")

      empty = File.join(dir, "empty").tap { |path| Dir.mkdir(path) }
      output, status = run(empty, candidate)
      expect(status.exitstatus).to eq(2)
      expect(output).to include("has no CSV exports")
      expect(output).not_to include("unexpected_differences=0")
      output, status = run(empty, File.join(dir, "nowhere"))
      expect(status.exitstatus).to eq(2)
    end
  end

  it "fails on a duplicate key, even when the first row is unchanged" do
    Dir.mktmpdir do |dir|
      baseline = File.join(dir, "baseline").tap { |path| Dir.mkdir(path) }
      candidate = File.join(dir, "candidate").tap { |path| Dir.mkdir(path) }
      File.write(File.join(baseline, "bpt-2027-01.csv"), "row_type,organization_id,event_id,gross\nevent,1,10,5.00\n")
      File.write(File.join(candidate, "bpt-2027-01.csv"),
        "row_type,organization_id,event_id,gross\nevent,1,10,5.00\nevent,1,10,9.99\n")

      output, status = run(baseline, candidate)
      expect(status.exitstatus).to eq(1)
      expect(output).to include("event/1/10 DUPLICATE KEY in candidate", "unexpected_differences=1")
    end
  end

  # A2 recheck finding 6 (e49e94d2): the baseline's file list is not the
  # whole comparison. A month only the candidate exported fails unless it is
  # explicitly authorized.
  it "fails on a candidate-only CSV unless the expected file authorizes it" do
    Dir.mktmpdir do |dir|
      baseline = File.join(dir, "baseline").tap { |path| Dir.mkdir(path) }
      candidate = File.join(dir, "candidate").tap { |path| Dir.mkdir(path) }
      body = "row_type,organization_id,event_id,gross\nevent,1,10,5.00\n"
      File.write(File.join(baseline, "cpa-2027-01.csv"), body)
      File.write(File.join(candidate, "cpa-2027-01.csv"), body)
      File.write(File.join(candidate, "bpt-2027-02.csv"), "row_type,organization_id,event_id,organizer_payouts\nevent,1,10,20.00\n")

      output, status = run(baseline, candidate)
      expect(status.exitstatus).to eq(1)
      expect(output).to include("bpt-2027-02.csv: CANDIDATE ONLY (no baseline export): 1 data rows",
        "bpt-2027-02.csv: event/1/10 ADDED: row_type=event; organization_id=1; event_id=10; organizer_payouts=20.00",
        "unexpected_differences=1")

      expected = File.join(dir, "expected.txt")
      File.write(expected, "bpt-2027-02.csv event/1/10\n")
      _output, status = run(baseline, candidate, expected)
      expect(status.exitstatus).to eq(1)

      File.write(expected, "# finance authorized the new month\nbpt-2027-02.csv candidate_only\n")
      output, status = run(baseline, candidate, expected)
      expect(status.exitstatus).to eq(0)
      expect(output).to include("CANDIDATE ONLY (no baseline export) (expected): 1 data rows", "unexpected_differences=0")
    end
  end

  it "accepts only an authorized zero baseline when there was no activity, and says no comparison ran" do
    Dir.mktmpdir do |dir|
      baseline = File.join(dir, "baseline").tap { |path| Dir.mkdir(path) }
      candidate = File.join(dir, "candidate").tap { |path| Dir.mkdir(path) }
      marker = File.join(baseline, "VERIFIED_ZERO_BASELINE")
      File.write(File.join(candidate, "cpa-2027-01.csv"), "row_type,organization_id,event_id,gross\n")

      File.write(marker, "reference=Pat Example\nverified_at=2026-11-26T00:40:00Z\nevidence=count 0\n")
      output, status = run(baseline, candidate)
      expect([status.exitstatus, output]).to match([2, a_string_including("structured finance reference")])

      File.write(marker, "reference=FIN-2026-11-001\nverified_at=2026-11-26T00:40:00Z\n" \
        "evidence=SELECT count(*) FROM payments WHERE provider_environment = 'live' -> 0\n")
      output, status = run(baseline, candidate)
      expect(status.exitstatus).to eq(0)
      expect(output).to include("comparison=verified_zero_baseline reference=FIN-2026-11-001", "no row comparison ran",
        "cpa-2027-01.csv: 0 data rows", "unexpected_differences=0")

      File.write(File.join(candidate, "cpa-2027-01.csv"), "row_type,organization_id,event_id,gross\nevent,1,10,5.00\n")
      output, status = run(baseline, candidate)
      expect(status.exitstatus).to eq(1)
      expect(output).to include("1 data rows (unexpected: the baseline recorded none)", "unexpected_differences=1")

      File.write(File.join(baseline, "cpa-2027-01.csv"), "row_type,organization_id,event_id,gross\n")
      _output, status = run(baseline, candidate)
      expect(status.exitstatus).to eq(2)
    end
  end
end
