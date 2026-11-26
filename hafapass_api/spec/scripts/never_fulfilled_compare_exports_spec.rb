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

  # A2 recheck finding 3 (7664e143): the verified zero baseline is checked
  # against the export pair the real exporters write on a database with no
  # activity (the authenticated admin endpoints): the CPA monthly export's
  # mandatory all-zero total row and the BPT events export's header only.
  describe "verified zero baseline against the real exporters", type: :request do
    let(:admin) { create(:user, :admin) }
    let(:period) { format("%04d-%02d", 2027, 1) }

    def download!(dir, path)
      get "/api/v1/admin/tax_reports/#{path}", params: { year: 2027, month: 1 }, headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      name = response.headers["Content-Disposition"][/filename="([^"]+)"/, 1]
      File.binwrite(File.join(dir, name), response.body)
      File.join(dir, name)
    end

    def rewrite_cpa(path)
      table = CSV.read(path, headers: true)
      yield table
      File.write(path, CSV.generate { |csv| csv << table.headers; table.each { |row| csv << row.fields } })
    end

    it "accepts the real zero-activity pair and rejects anything less or anything more" do
      Dir.mktmpdir do |dir|
        baseline = File.join(dir, "baseline").tap { |path| Dir.mkdir(path) }
        candidate = File.join(dir, "candidate").tap { |path| Dir.mkdir(path) }
        marker = File.join(baseline, "VERIFIED_ZERO_BASELINE")
        File.write(marker, "reference=FIN-2026-11-001\nverified_at=2026-11-26T00:40:00Z\n" \
          "evidence=SELECT count(*) FROM payments WHERE provider_environment = 'live' -> 0\n")
        cpa = download!(candidate, "cpa_monthly_export")
        bpt = download!(candidate, "bpt_events_export")
        expect(File.basename(cpa)).to eq("hafapass-cpa-monthly-#{period}.csv")
        expect(File.basename(bpt)).to eq("hafapass-bpt-events-#{period}.csv")
        cpa_rows = CSV.read(cpa, headers: true)
        expect(cpa_rows.map { |row| row["row_type"] }).to eq(["total"])
        expect(CSV.read(bpt, headers: true).size).to eq(0)
        pristine = { cpa => File.binread(cpa), bpt => File.binread(bpt) }
        restore = -> { pristine.each { |path, body| File.binwrite(path, body) } }

        output, status = run(baseline, candidate)
        expect([status.exitstatus, output]).to match([0, a_string_including(
          "comparison=verified_zero_baseline reference=FIN-2026-11-001", "no row comparison ran",
          "hafapass-cpa-monthly-#{period}.csv: one all-zero total row", "hafapass-bpt-events-#{period}.csv: 0 data rows",
          "unexpected_differences=0")])

        # Each half alone, or neither, is no evidence.
        File.delete(cpa)
        output, status = run(baseline, candidate)
        expect([status.exitstatus, output]).to match([2, a_string_including("#{period} needs both", "missing cpa")])
        restore.call
        File.delete(bpt)
        output, status = run(baseline, candidate)
        expect([status.exitstatus, output]).to match([2, a_string_including("missing bpt")])
        File.delete(cpa)
        output, status = run(baseline, candidate)
        expect([status.exitstatus, output]).to match([2, a_string_including("has no CSV exports")])
        expect(output).not_to include("unexpected_differences=0")
        restore.call

        # A second export of one kind, or a file that is neither, is unusable.
        File.binwrite(File.join(candidate, "copy-cpa-#{period}.csv"), pristine[cpa])
        _output, status = run(baseline, candidate)
        expect(status.exitstatus).to eq(2)
        File.delete(File.join(candidate, "copy-cpa-#{period}.csv"))
        File.write(File.join(candidate, "notes-#{period}.csv"), "row_type,organization_id,event_id,gross\n")
        output, status = run(baseline, candidate)
        expect([status.exitstatus, output]).to match([2, a_string_including("neither a CPA monthly nor a BPT events export")])
        File.delete(File.join(candidate, "notes-#{period}.csv"))

        # Content: a nonzero amount, a flag or note, a wrong or second row, a
        # wrong month, the incomplete-export marker, or any BPT row.
        {
          "a nonzero amount" => ->(table) { table.first["proceeds_collected"] = "5.00" },
          "a nonzero quantity" => ->(table) { table.first["buyer_owed_captures_gross"] = "0.01" },
          "an exception flag" => ->(table) { table.first["reconciliation_exception_flag"] = "yes" },
          "a note" => ->(table) { table.first["prior_period_note"] = "Payout relates to Dec 2026" },
          "a nonprofit row count" => ->(table) { table.first["nonprofit_exemption_note"] = table.first["nonprofit_exemption_note"].sub(/\A0/, "1") },
          "an event row in place of the total" => ->(table) { table.first["row_type"] = "event" },
          "a wrong month" => ->(table) { table.first["month"] = "2027-02" },
          "an organization on the total" => ->(table) { table.first["organization_id"] = "1" },
          "a second row" => ->(table) { table << CSV::Row.new(table.headers, table.first.fields) }
        }.each do |label, change|
          rewrite_cpa(cpa, &change)
          output, status = run(baseline, candidate)
          expect([label, status.exitstatus]).to eq([label, 1])
          expect(output).not_to include("unexpected_differences=0")
          restore.call
        end
        File.write(cpa, pristine[cpa] + CSV.generate_line([SpreadsheetExport::INCOMPLETE_MARKER], force_quotes: true))
        _output, status = run(baseline, candidate)
        expect(status.exitstatus).to eq(1)
        restore.call
        File.write(bpt, pristine[bpt] + CSV.generate_line([period, 1, 10, "1.00", "0.00", "1.00", "0.00", "0.00", "0.00", "USD"]))
        output, status = run(baseline, candidate)
        expect([status.exitstatus, output]).to match([1, a_string_including("1 data rows (unexpected: the baseline recorded none)")])
        restore.call

        # The record itself, and a record alongside baseline CSVs.
        File.write(marker, "reference=Pat Example\nverified_at=2026-11-26T00:40:00Z\nevidence=count 0\n")
        output, status = run(baseline, candidate)
        expect([status.exitstatus, output]).to match([2, a_string_including("structured finance reference")])
        File.write(marker, "reference=FIN-2026-11-001\nverified_at=2026-11-26T00:40:00Z\nevidence=count 0\n")
        File.binwrite(File.join(baseline, File.basename(cpa)), pristine[cpa])
        _output, status = run(baseline, candidate)
        expect(status.exitstatus).to eq(2)
      end
    end
  end
end
