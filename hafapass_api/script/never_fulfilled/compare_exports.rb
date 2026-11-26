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
require "csv"

KEY_COLUMNS = %w[period row_type organization_id event_id].freeze

def load(path)
  table = CSV.read(path, headers: true)
  [table.headers, table.map(&:fields)]
end

def key_for(header, fields)
  KEY_COLUMNS.filter_map { |column| (index = header.index(column)) && fields[index] }.join("/")
end

baseline_dir, candidate_dir, expected_file = ARGV
abort "usage: compare_exports.rb BASELINE_DIR CANDIDATE_DIR [EXPECTED_FILE]" unless baseline_dir && candidate_dir

expected = if expected_file
  File.readlines(expected_file, chomp: true).reject { |line| line.strip.empty? || line.start_with?("#") }
    .map { |line| line.split(/\s+/, 2) }.to_set
else
  Set.new
end
unexpected = 0

Dir[File.join(baseline_dir, "*.csv")].sort.each do |baseline_path|
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
    puts "#{name}: #{key} ADDED#{' (expected)' if allowed}"
  end
  puts "#{name}: #{same}/#{old_rows.length} rows byte-identical in the #{old_header.length} pre-existing columns; " \
    "appended columns: #{appended.empty? ? 'none' : appended.join(',')}"
end
puts "unexpected_differences=#{unexpected}"
exit(unexpected.zero? ? 0 : 1)
