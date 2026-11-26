# frozen_string_literal: true

# Like-for-like comparison of saved CPA and BPT CSV exports across the A2
# release (docs/NEVER_FULFILLED_RELEASE.md "A2 release", design §10.5).
# Plain Ruby, no database: run it on the CSV files home base downloaded
# before and after the deploy.
#
#   ruby script/never_fulfilled/compare_exports.rb BASELINE_DIR CANDIDATE_DIR [EXPECTED_FILE]
#
# For every CSV in BASELINE_DIR with the same name in CANDIDATE_DIR:
#   - the baseline header must be an exact prefix of the candidate header
#     (A2 only appends columns);
#   - rows are matched by their key (period, row_type, organization_id,
#     event_id, whichever the file has) and every pre-existing column is
#     compared byte for byte;
#   - appended columns are listed separately for review, never compared.
# EXPECTED_FILE lists "<file> <key>" lines (key joined with "/") for rows the
# rehearsal diff says may change (for example an event with a classified
# capture). Exit status 0 only when every difference is expected.
#
# No false success (CodeRabbit 4703321699, 4703321701): both directories must
# exist and BASELINE_DIR must hold at least one CSV; a key that appears twice
# in either export is an unexpected difference. When production genuinely had
# no live activity, there is no baseline CSV to compare: BASELINE_DIR then
# holds only VERIFIED_ZERO_BASELINE, finance's record of that fact:
#
#   reference=FIN-2026-11-001        (structured finance reference, no name)
#   verified_at=2026-11-26T00:40:00Z (ISO8601 with offset)
#   evidence=<the read-only query and its zero result>
#
# and every candidate CSV must then have no data rows. The output says
# comparison=verified_zero_baseline, never that a comparison ran.
# Exit status 2 for unusable input (missing or empty inventory, an invalid
# or conflicting zero-baseline record).
require "csv"
require "set"
require "time"

KEY_COLUMNS = %w[period row_type organization_id event_id].freeze

def load(path)
  table = CSV.read(path, headers: true)
  [table.headers, table.map(&:fields)]
end

def key_for(header, fields)
  KEY_COLUMNS.filter_map { |column| (index = header.index(column)) && fields[index] }.join("/")
end

ZERO_MARKER = "VERIFIED_ZERO_BASELINE"
FINANCE_REFERENCE = /\A[A-Z]{2,10}-[A-Z0-9][A-Z0-9-]{0,40}\z/

def unusable(message)
  warn "compare_exports: #{message}"
  puts "unexpected_differences=unusable_input"
  exit 2
end

def duplicates(header, rows)
  rows.map { |fields| key_for(header, fields) }.tally.select { |_key, count| count > 1 }.keys
end

baseline_dir, candidate_dir, expected_file = ARGV
abort "usage: compare_exports.rb BASELINE_DIR CANDIDATE_DIR [EXPECTED_FILE]" unless baseline_dir && candidate_dir
unusable("baseline directory #{baseline_dir} does not exist") unless File.directory?(baseline_dir)
unusable("candidate directory #{candidate_dir} does not exist") unless File.directory?(candidate_dir)
baseline_paths = Dir[File.join(baseline_dir, "*.csv")].sort
zero_marker = File.join(baseline_dir, ZERO_MARKER)

if File.exist?(zero_marker)
  unusable("#{ZERO_MARKER} and baseline CSVs together: a zero baseline has no exports") if baseline_paths.any?
  record = File.readlines(zero_marker, chomp: true).filter_map do |line|
    key, value = line.split("=", 2)
    [key.strip, value.to_s.strip] if value && !line.start_with?("#")
  end.to_h
  unless record["reference"].to_s.match?(FINANCE_REFERENCE)
    unusable("#{ZERO_MARKER} needs reference=<structured finance reference, e.g. FIN-2026-11-001>")
  end
  begin
    raise ArgumentError unless record["verified_at"].to_s.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)

    Time.iso8601(record["verified_at"])
  rescue ArgumentError
    unusable("#{ZERO_MARKER} needs verified_at=<ISO8601 time with offset>")
  end
  unusable("#{ZERO_MARKER} needs evidence=<the read-only query and its zero result>") if record["evidence"].to_s.empty?

  puts "comparison=verified_zero_baseline reference=#{record['reference']} verified_at=#{record['verified_at']} " \
    "(no baseline rows existed, so no row comparison ran)"
  rows_found = 0
  Dir[File.join(candidate_dir, "*.csv")].sort.each do |path|
    _header, rows = load(path)
    rows_found += rows.length
    puts "#{File.basename(path)}: #{rows.length} data rows#{' (unexpected: the baseline recorded none)' if rows.any?}"
  end
  puts "unexpected_differences=#{rows_found}"
  exit(rows_found.zero? ? 0 : 1)
end
unusable("baseline directory #{baseline_dir} has no CSV exports (record #{ZERO_MARKER} if there was no activity)") if baseline_paths.empty?

expected = if expected_file
  File.readlines(expected_file, chomp: true).reject { |line| line.strip.empty? || line.start_with?("#") }
    .map { |line| line.split(/\s+/, 2) }.to_set
else
  Set.new
end
unexpected = 0

baseline_paths.each do |baseline_path|
  name = File.basename(baseline_path)
  candidate_path = File.join(candidate_dir, name)
  unless File.exist?(candidate_path)
    puts "#{name}: MISSING in candidate"
    unexpected += 1
    next
  end

  old_header, old_rows = load(baseline_path)
  new_header, new_rows = load(candidate_path)
  unless new_header.first(old_header.length) == old_header
    puts "#{name}: HEADER CHANGED (pre-existing columns must keep their names and order)"
    unexpected += 1
    next
  end
  appended = new_header.drop(old_header.length)
  { "baseline" => duplicates(old_header, old_rows), "candidate" => duplicates(new_header, new_rows) }.each do |side, keys|
    keys.each do |key|
      unexpected += 1
      puts "#{name}: #{key} DUPLICATE KEY in #{side}"
    end
  end
  new_by_key = new_rows.group_by { |fields| key_for(new_header, fields) }
  same = 0
  old_rows.each do |fields|
    key = key_for(old_header, fields)
    match = Array(new_by_key.delete(key)).first
    if match.nil?
      allowed = expected.include?([name, key])
      unexpected += 1 unless allowed
      puts "#{name}: #{key} REMOVED#{' (expected)' if allowed}"
      next
    end
    diffs = old_header.each_index.reject { |index| fields[index] == match[index] }
    if diffs.empty?
      same += 1
    else
      allowed = expected.include?([name, key])
      unexpected += 1 unless allowed
      puts "#{name}: #{key} CHANGED#{' (expected)' if allowed}: " +
        diffs.map { |index| "#{old_header[index]} #{fields[index].inspect}->#{match[index].inspect}" }.join("; ")
    end
    extra = appended.each_with_index.filter_map do |column, offset|
      value = match[old_header.length + offset]
      "#{column}=#{value}" unless value.to_s.empty? || value.to_s.match?(/\A0(?:\.0+)?\z/)
    end
    puts "#{name}: #{key} appended: #{extra.join('; ')}" if extra.any?
  end
  new_by_key.each do |key, rows|
    allowed = expected.include?([name, key])
    unexpected += rows.length unless allowed
    rows.each do |fields|
      puts "#{name}: #{key} ADDED#{' (expected)' if allowed}: " + new_header.zip(fields).map { |column, value| "#{column}=#{value}" }.join("; ")
    end
  end
  puts "#{name}: #{same}/#{old_rows.length} rows byte-identical in the #{old_header.length} pre-existing columns; " \
    "appended columns: #{appended.empty? ? 'none' : appended.join(',')}"
end
puts "unexpected_differences=#{unexpected}"
exit(unexpected.zero? ? 0 : 1)
