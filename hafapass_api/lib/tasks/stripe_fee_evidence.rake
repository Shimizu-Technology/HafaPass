# frozen_string_literal: true

# Backfill path for verified processing facts recorded before
# stripe_fee_evidences.facts_recorded_at existed (migration 20261126170000,
# design §8.10.9). Nothing schedules this. It is a dry run unless DRY_RUN=0.
# A write stamps each listed row with the database clock at the time it runs
# (never an earlier time), so the facts enter the period of the backfill as a
# current-period recognition; the CPA projection alerts them until then. A
# write on a shared or production database is part of an authorized release.
namespace :stripe_fee_evidence do
  desc "Report (DRY_RUN=1, default) or stamp facts_recorded_at on verified payment-scope fee facts that have none"
  task stamp_facts: :environment do
    dry_run = ENV.fetch("DRY_RUN", "1") != "0"
    scope = StripeFeeEvidence.where(facts_recorded_at: nil, fee_component_id: nil,
      last_error_code: StripeProcessingFees::PAYMENT_SCOPE_DEFERRED_CODE).where.not(evidence_digest: nil)
      .where(payment_id: UnfulfilledCapture.payment_scope.select(:payment_id)).order(:id)
    puts "stripe_fee_evidence:stamp_facts #{dry_run ? 'DRY RUN (nothing written)' : 'WRITE'}"
    scope.find_each do |evidence|
      unless dry_run
        StripeFeeEvidence.transaction do
          FinancialIntegrity.with_evidence(:fee_facts_backfill, evidence.id) { evidence.touch }
        end
      end
      evidence.reload
      puts [evidence.id, evidence.payment_id, evidence.fee_cents, evidence.facts_recorded_at&.iso8601].join("\t")
    end
  end
end
