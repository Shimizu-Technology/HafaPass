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
end
