# frozen_string_literal: true

class DataRetentionPurgeJob < ApplicationJob
  queue_as :low

  # Never log identifiers or record contents. Configuration is deliberately
  # conservative: only rules with safe, tested disposal paths run here.
  RUNNABLE = %w[orders payouts organizer_tax_informations audit_logs message_deliveries
    tickets registration_responses ticket_transfers guest_list_entries support_notes admission_actions
    admission_manifests message_provider_events privacy_requests marketing_unsubscribes
    payments refunds disputes
    payment_events fee_components fee_changes fee_change_notices reconciliation_exceptions
    card_present_payment_attempts webhook_events].freeze

  def perform(at: Time.current)
    dry_run = DataRetention.dry_run?
    counts = Hash.new(0)
    RUNNABLE.each do |table|
      rule = DataRetention.schedule.fetch(table)
      cutoff = DataRetention.cutoff(rule.fetch("period"), at: at)
      next unless cutoff

      model = table.classify.constantize
      relation = model.where(rule.fetch("trigger") => ...cutoff)
      relation = relation.where(retention_anonymized_at: nil) if model.column_names.include?("retention_anonymized_at")
      relation.in_batches(of: DataRetention::BATCH_SIZE) do |batch|
        batch.each do |record|
          next if RetentionGuard.protected?(record)
          next if record.is_a?(Order) && record.tickets.exists? && record.event.starts_at&.after?(at)
          next if record.is_a?(Ticket) && record.event.starts_at&.after?(at)
          next if record.is_a?(PrivacyRequest) && record.executed_at.nil?
          next if record.is_a?(MessageDelivery) && (record.queued? || record.delayed?)
          related_order = record.order if record.respond_to?(:order)
          related_order ||= record.payment&.order if record.respond_to?(:payment)
          related_order ||= record.payment_event&.payment&.order if record.respond_to?(:payment_event)
          related_order ||= record.ticket&.order if record.respond_to?(:ticket)
          if related_order.nil? && record.respond_to?(:message_delivery)
            delivery = record.message_delivery
            related_order = delivery&.order || delivery&.ticket&.order
          end
          next if related_order && RetentionGuard.protected?(related_order)
          next if record.is_a?(Payout) && !record.status_paid?
          next if record.is_a?(OrganizerTaxInformation) && Payout.where(organization_id: record.organization_id)
            .where("paid_at >= ? OR paid_at IS NULL", cutoff).exists?

          if dry_run
            counts[table] += 1
            next
          end

          written = false
          LegalHold.with_retention_lock do
            record.with_lock do
              if RetentionGuard.protected?(record)
                Rails.logger.info("[DataRetention] skipped protected #{table} record")
                next
              end
              result = case rule.fetch("action")
              when "delete"
                record.destroy!
                true
              when "anonymize" then DataRetention.anonymize!(record)
              end
              written = result != false
            end
          end
          counts[table] += 1 if written
        end
      end
    end
    pending_cutoff = DataRetention.cutoff("90_days", at: at)
    Order.where(status: [:pending, :expired]).where("COALESCE(expired_at, expires_at, created_at) < ?", pending_cutoff)
      .in_batches(of: DataRetention::BATCH_SIZE) do |batch|
        batch.each do |order|
          if dry_run
            counts["abandoned_orders"] += 1 if DataRetention.pending_order_purgeable?(order)
          else
            counts["abandoned_orders"] += 1 if DataRetention.delete_pending_order!(order)
          end
        end
      end
    Rails.logger.info("[DataRetention] dry_run=#{dry_run} counts=#{counts.sort.to_h.to_json}")
    counts
  end
end
