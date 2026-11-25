# frozen_string_literal: true

# docs/design/never-fulfilled-captures.md §4.5 and §10.5. Nothing schedules
# these. reconcile is a dry run unless DRY_RUN=0; an actual run on a shared or
# production database needs an authorized disposition (§10.5).
namespace :never_fulfilled do
  desc "Report (DRY_RUN=1, default) or write never-fulfilled backfill classifications and return postings"
  task reconcile: :environment do
    dry_run = ENV.fetch("DRY_RUN", "1") != "0"
    ids = ENV["PAYMENT_IDS"].to_s.split(",").map(&:strip).reject(&:empty?).presence
    report = Commerce::NeverFulfilledReconcile.call(dry_run: dry_run, payment_ids: ids)
    puts "never_fulfilled:reconcile #{dry_run ? 'DRY RUN (nothing written)' : 'WRITE'}"
    puts "dispositions: #{report.counts.sort.to_h}"
    puts "reasons: #{report.reasons.sort.to_h}"
    report.assessments.each do |item|
      puts [item.payment_id, item.order_id, item.disposition, item.reason, "movements=#{item.movement_count}"].compact.join("\t")
    end
  end

  # Same SQL as `psql -f script/never_fulfilled/release_evidence.sql`, in one
  # READ ONLY transaction that is rolled back; the in-flight bound comes from
  # the code (Commerce::BuyerRepayment.in_flight_bound).
  desc "Read-only A1 release evidence (R1_SHA=<commit> R1_LIVE_AT=<ISO-8601 UTC>); BASELINE=1 for the pre-R1 baseline"
  task release_evidence: :environment do
    baseline = ENV["BASELINE"] == "1"
    path = Rails.root.join("script/never_fulfilled/#{baseline ? 'baseline_before_r1' : 'release_evidence'}.sql")
    connection = ActiveRecord::Base.connection
    unless baseline
      sha = ENV.fetch("R1_SHA")
      raise ArgumentError, "R1_SHA must be a 40-hex commit" unless sha.match?(/\A\h{40}\z/)

      live_at = Time.iso8601(ENV.fetch("R1_LIVE_AT")).utc.iso8601
      variables = { "r1_sha" => sha, "r1_live_at" => live_at, "bound_seconds" => Commerce::BuyerRepayment.in_flight_bound.to_i.to_s }
    end
    statements = File.read(path).gsub(/^--.*$/, "").split(";").map(&:strip).reject(&:empty?)
    statements = statements.reject { |sql| sql.match?(/\A(BEGIN|ROLLBACK)/i) }
    connection.transaction do
      connection.execute("SET TRANSACTION READ ONLY")
      statements.each do |sql|
        sql = sql.gsub(/:'(\w+)'/) { connection.quote(variables.fetch(Regexp.last_match(1))) } if variables
        result = connection.exec_query(sql)
        result.rows.each { |row| puts result.columns.zip(row).map { |column, value| "#{column}=#{value}" }.join("\t") }
        puts "#{sql[/'(\w+)' AS section/, 1]}: (none)" if result.rows.empty?
      end
      raise ActiveRecord::Rollback
    end
  end

  desc "Read-only counts: unclassified late-capture payments and unposted movements on classified payments"
  task verify: :environment do
    report = Commerce::NeverFulfilledReconcile.call(dry_run: true)
    pending = report.assessments.reject { |item| %w[held reconciled].include?(item.disposition) }
    puts "unclassified_or_unposted=#{pending.count} dispositions=#{report.counts.sort.to_h}"
    puts "unposted_movement_payments=#{Commerce::NeverFulfilledReconcile.unposted_movement_payment_ids.count}"
  end
end
