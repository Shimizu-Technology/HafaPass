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
# capture). Exit status 0 only when every difference is expected. Both
# inventories must match: a CSV only the candidate has is unexpected unless
# EXPECTED_FILE has a "<file> candidate_only" line for it.
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
# and the candidate must hold the real exporters' pair for every month it
# exported (hafapass-cpa-monthly-YYYY-MM.csv with its one all-zero total
# row, hafapass-bpt-events-YYYY-MM.csv with its header only; any other CSV,
# a second row, a nonzero amount or a missing half is rejected). Each file's
# name must be its exporter's for the kind its header shows, so a swapped or
# renamed pair is unusable. Each file's
# header must be its exporter's exact, versioned full header (ZERO_SCHEMAS),
# so a truncated, reordered or extended export is unusable. The output
# says comparison=verified_zero_baseline, never that a comparison ran.
#
# In both modes every CSV must be well formed (A2 recheck finding 3,
# 758485ae; CodeRabbit 4706251726): a header row (a zero-byte file is not an
# export), unique, non-blank header names and every row exactly as wide as
# its header; otherwise it is unusable input (exit 2).
#
#   ruby script/never_fulfilled/compare_exports.rb --print-schemas
# prints the versioned zero-baseline schemas as JSON.
# Exit status 2 for unusable input (missing or empty inventory, an invalid
# or conflicting zero-baseline record).
require "csv"
require "set"
require "time"

KEY_COLUMNS = %w[period row_type organization_id event_id].freeze

# Raw rows, so a short or long row keeps its real width (a headers: true
# table pads or folds it).
def load(path)
  rows = CSV.read(path)
  [rows.shift || [], rows]
end

def key_for(header, fields)
  KEY_COLUMNS.filter_map { |column| (index = header.index(column)) && fields[index] }.join("/")
end

ZERO_MARKER = "VERIFIED_ZERO_BASELINE"
CANDIDATE_ONLY = "candidate_only"
FINANCE_REFERENCE = /\A[A-Z]{2,10}-[A-Z0-9][A-Z0-9-]{0,40}\z/

def unusable(message)
  warn "compare_exports: #{message}"
  puts "unexpected_differences=unusable_input"
  exit 2
end

# The verified zero baseline's export pair: the exporters' exact, versioned
# full headers (A2 recheck finding 3, 758485ae). A file is accepted only
# when its header is one of these exactly, column for column, so a
# truncated export (monetary columns removed), a reordered one, a renamed
# or an extra column, or a duplicate header (where a later cell would hide
# an earlier one: organizer_payouts_made 100.00 then 0.00) is never zero
# evidence. Keep these equal to CpaMonthlyReport::HEADER and
# Api::V1::Admin::TaxReportsController::BPT_EVENT_HEADER (the spec checks
# them through --print-schemas); a new exporter version is a new entry.
ZERO_SCHEMAS = {
  "cpa" => {
    "cpa-monthly-a2-1" => %w[
      row_type month organization_id event_id w9_nonprofit_classification drt_exemption_verified
      nonprofit_exemption_note opening_custodial_liability proceeds_collected proceeds_refunded chargebacks
      organizer_processing_deducted other_adjustments organizer_payouts_made payout_reversals
      closing_custodial_liability closing_custodial_payables closing_organizer_deficits opening_buyer_refunds_owed
      buyer_refund_captures buyer_refunds_paid closing_buyer_refunds_owed reserve_held reserve_released
      ending_reserve_balance unallocated_refunds_exception cumulative_unallocated_refunds_exception
      reconciliation_exception_flag reconciliation_exception_note prior_period_note non_custodial_settlement_bridge
      backup_withholding_memo fee_revenue_gross fee_refunds fee_revenue_net stripe_processing_costs_informational
      bpt_base_fee_revenue_estimate estimated_bpt_rate_pct estimated_bpt_on_fee_revenue_estimate currency
      opening_buyer_owed_gross buyer_owed_captures_gross buyer_owed_returned_gross closing_buyer_owed_gross
      buyer_overpaid_in_month_gross buyer_overpaid_cumulative_gross closing_buyer_owed_second_capture_principal
      closing_buyer_owed_fee_tax_share closing_buyer_refunds_owed_unclassified_legacy classified_allocation_policy
    ].freeze
  }.freeze,
  "bpt" => {
    "bpt-events-a2-1" => %w[
      month organization_id event_id gross_service_fees refunded_service_fees net_service_fees
      stripe_processing_fees_informational ticket_face_value_collected_as_agent organizer_payouts currency
    ].freeze
  }.freeze
}.freeze
# The file name each exporter writes (CodeRabbit 4705527114): the kind its
# header shows must be the kind its name says, for the month in its name.
ZERO_FILE_NAMES = {
  "cpa" => /\Ahafapass-cpa-monthly-(\d{4}-(?:0[1-9]|1[0-2]))\.csv\z/,
  "bpt" => /\Ahafapass-bpt-events-(\d{4}-(?:0[1-9]|1[0-2]))\.csv\z/
}.freeze
ZERO_FILE_LABELS = { "cpa" => "hafapass-cpa-monthly-YYYY-MM.csv", "bpt" => "hafapass-bpt-events-YYYY-MM.csv" }.freeze
# The leading columns that say which exporter a file claims to come from.
ZERO_KINDS = {
  "cpa" => %w[row_type month organization_id event_id],
  "bpt" => %w[month organization_id event_id gross_service_fees]
}.freeze

if ARGV == ["--print-schemas"]
  require "json"
  puts JSON.generate(ZERO_SCHEMAS)
  exit 0
end

# Every CSV, in either mode: a header row, unique, non-blank header names
# and every row exactly as wide as the header. A duplicate name would let one
# cell shadow another wherever columns are read by name; a short or long row
# (or an exporter's incomplete-export marker line) is not a complete export.
# CodeRabbit 4706251726: a zero-byte (or blank-line-only) file has no header,
# so two of them would otherwise compare as 0/0 identical rows; every
# exporter writes its header, even a header-only BPT file.
def shape_problems(header, rows)
  problems = []
  problems << "no header row (empty file)" if header.empty?
  duplicate = header.tally.select { |_name, count| count > 1 }.keys
  problems << "duplicate header #{duplicate.map(&:inspect).join(', ')}" if duplicate.any?
  problems << "blank header name" if header.any? { |name| name.to_s.strip.empty? }
  rows.each_with_index do |fields, index|
    next if fields.length == header.length

    problems << "row #{index + 2} has #{fields.length} cells for #{header.length} header columns"
  end
  problems
end

def load_checked(path)
  header, rows = load(path)
  problems = shape_problems(header, rows)
  unusable("#{File.basename(path)} is not a well-formed export: #{problems.join('; ')}") if problems.any?
  [header, rows]
end

# CPA total-row cells that are labels, not amounts or counts: checked for
# their exact zero-activity value (the nonprofit note carries a row count,
# so only its zero form passes), or (the rate and the policy note) free.
ZERO_CPA_LABELS = { "row_type" => "total", "currency" => "USD", "reconciliation_exception_flag" => "no",
  "drt_exemption_verified" => "not_tracked",
  "nonprofit_exemption_note" => "0 W-9 nonprofit row(s) (current at export time); DRT exemption not tracked" }.freeze
ZERO_CPA_FREE = %w[month estimated_bpt_rate_pct classified_allocation_policy].freeze
ZERO_VALUE = /\A-?0+(?:\.0+)?\z/

def zero_cpa_problems(header, rows, period)
  return ["#{rows.length} rows (expected exactly one total row)"] unless rows.length == 1

  row = header.zip(rows.first).to_h
  problems = []
  problems << "month #{row['month'].inspect} (expected #{period})" unless row["month"] == period
  ZERO_CPA_LABELS.each do |column, value|
    problems << "#{column}=#{row[column].inspect} (expected #{value})" unless row[column] == value
  end
  row.each do |column, value|
    next if ZERO_CPA_LABELS.key?(column) || ZERO_CPA_FREE.include?(column)
    next if value.to_s.empty? || value.to_s.match?(ZERO_VALUE)

    problems << "#{column}=#{value} (unexpected: the baseline recorded no activity)"
  end
  problems
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

  # CodeRabbit 4704013222 and A2 recheck finding 3 (7664e143): zero activity
  # is shown by the candidate's own export pair for each month, as the real
  # exporters write it: the CPA monthly export with its one mandatory total
  # row, every monetary and quantity value zero, and the BPT events export
  # with its header only. Both kinds are required for every month, so a
  # header-only BPT file alone, or a candidate run that exported nothing,
  # is no evidence of zero activity.
  candidate_paths = Dir[File.join(candidate_dir, "*.csv")].sort
  if candidate_paths.empty?
    unusable("candidate directory #{candidate_dir} has no CSV exports; export the candidate's CPA monthly and BPT " \
      "events files before accepting a verified zero baseline")
  end
  exports = Hash.new { |hash, period| hash[period] = {} }
  candidate_paths.each do |path|
    name = File.basename(path)
    header, rows = load_checked(path)
    kind = ZERO_KINDS.find { |_kind, prefix| header.first(prefix.length) == prefix }&.first
    unusable("#{name} is neither a CPA monthly nor a BPT events export") unless kind
    period = name[ZERO_FILE_NAMES.fetch(kind), 1]
    unless period
      named = ZERO_FILE_NAMES.find { |_kind, pattern| name.match?(pattern) }&.first
      unusable(named ? "#{name} is named as a #{named} export but its header is the #{kind} exporter's" :
        "#{name} is not named as the #{kind} exporter names it (#{ZERO_FILE_LABELS.fetch(kind)})")
    end
    version = ZERO_SCHEMAS.fetch(kind).find { |_version, columns| columns == header }&.first
    unless version
      expected = ZERO_SCHEMAS.fetch(kind).values.last
      missing = expected - header
      extra = header - expected
      detail = [("missing #{missing.join(',')}" if missing.any?), ("unexpected #{extra.join(',')}" if extra.any?),
        ("columns out of order" if missing.empty? && extra.empty?)].compact.join("; ")
      unusable("#{name} does not have the #{kind} exporter's exact header (#{ZERO_SCHEMAS.fetch(kind).keys.join(', ')}): #{detail}")
    end
    unusable("two #{kind} exports for #{period} (#{exports[period][kind][:name]}, #{name})") if exports[period].key?(kind)
    exports[period][kind] = { name: name, header: header, rows: rows, version: version }
  end
  exports.each do |period, kinds|
    missing = ZERO_KINDS.keys - kinds.keys
    unusable("#{period} needs both the CPA monthly and the BPT events export; missing #{missing.join(' and ')}") if missing.any?
  end
  puts "comparison=verified_zero_baseline reference=#{record['reference']} verified_at=#{record['verified_at']} " \
    "(no baseline rows existed, so no row comparison ran)"
  activity = 0
  exports.sort.each do |period, kinds|
    cpa = kinds.fetch("cpa")
    problems = zero_cpa_problems(cpa[:header], cpa[:rows], period)
    activity += problems.length
    puts "#{cpa[:name]}: schema #{cpa[:version]}; #{problems.empty? ? 'one all-zero total row' : problems.join('; ')}"
    bpt = kinds.fetch("bpt")
    activity += bpt[:rows].length
    puts "#{bpt[:name]}: schema #{bpt[:version]}; #{bpt[:rows].length} data rows#{' (unexpected: the baseline recorded none)' if bpt[:rows].any?}"
  end
  puts "unexpected_differences=#{activity}"
  exit(activity.zero? ? 0 : 1)
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

  old_header, old_rows = load_checked(baseline_path)
  new_header, new_rows = load_checked(candidate_path)
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
# Review finding 6 (e49e94d2): the inventories must match. A CSV only the
# candidate has (a month or report the baseline never exported) is an
# unexpected difference unless EXPECTED_FILE authorizes it with a
# "<file> candidate_only" line; its rows are listed either way.
baseline_names = baseline_paths.map { |path| File.basename(path) }.to_set
Dir[File.join(candidate_dir, "*.csv")].sort.each do |candidate_path|
  name = File.basename(candidate_path)
  next if baseline_names.include?(name)

  header, rows = load_checked(candidate_path)
  allowed = expected.include?([name, CANDIDATE_ONLY])
  unexpected += 1 unless allowed
  puts "#{name}: CANDIDATE ONLY (no baseline export)#{' (expected)' if allowed}: #{rows.length} data rows"
  rows.each do |fields|
    puts "#{name}: #{key_for(header, fields)} ADDED: " + header.zip(fields).map { |column, value| "#{column}=#{value}" }.join("; ")
  end
end
puts "unexpected_differences=#{unexpected}"
exit(unexpected.zero? ? 0 : 1)
