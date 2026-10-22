# frozen_string_literal: true

class DataRetentionPurgeJob < ApplicationJob
  queue_as :low

  # Never log identifiers or record contents. Configuration is deliberately
  # conservative: only rules with safe, tested disposal paths run here.
  RUNNABLE = %w[orders payouts organizer_tax_informations audit_logs message_deliveries
    tickets registration_responses ticket_transfers guest_list_entries support_notes admission_actions
    admission_manifests message_provider_events privacy_requests marketing_unsubscribes
    organizer_sales_export_requests payments refunds disputes
    payment_events fee_components reconciliation_exceptions card_present_payment_attempts webhook_events].freeze

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
          next if DataRetention.held?(record)
          next if record.is_a?(Order) && DataRetention.unresolved_money?(record)
          related_order = if record.respond_to?(:order)
            record.order
          elsif record.respond_to?(:payment)
            record.payment&.order
          elsif record.respond_to?(:payment_event)
            record.payment_event&.payment&.order
          elsif record.respond_to?(:ticket)
            record.ticket&.order
          elsif record.respond_to?(:message_delivery)
            delivery = record.message_delivery
            delivery&.order || delivery&.ticket&.order
          end
          next if related_order && DataRetention.unresolved_money?(related_order)
          next if record.is_a?(Payout) && !record.status_paid?
          next if record.is_a?(OrganizerTaxInformation) && Payout.where(organization_id: record.organization_id)
            .where("paid_at >= ? OR paid_at IS NULL", cutoff).exists?
          next if record.is_a?(OrganizerSalesExportRequest) && record.expires_at.nil?

          if dry_run
            counts[table] += 1
            next
          end

          case rule.fetch("action")
          when "delete"
            if record.is_a?(OrganizerSalesExportRequest)
              next unless record.storage_key.blank? || !S3Service.configured? ||
                begin
                  S3Service.delete_private_export!(record.storage_key)
                  true
                rescue S3Service::UploadError, Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError
                  false
                end
            end
            record.destroy!
          when "anonymize" then record.with_lock { DataRetention.anonymize!(record) }
          end
          counts[table] += 1
        end
      end
    end
    pending_cutoff = DataRetention.cutoff("90_days", at: at)
    Order.where(status: [:pending, :expired]).where("COALESCE(expired_at, expires_at, created_at) < ?", pending_cutoff)
      .in_batches(of: DataRetention::BATCH_SIZE) do |batch|
        batch.each do |order|
          next if DataRetention.held?(order) || DataRetention.unresolved_money?(order)
          next if order.payments.exists? || order.refunds.exists? || order.disputes.exists? || order.tickets.exists?

          counts["abandoned_orders"] += 1
          DataRetention.delete_pending_order!(order) unless dry_run
        end
      end
    Rails.logger.info("[DataRetention] dry_run=#{dry_run} counts=#{counts.sort.to_h.to_json}")
    counts
  end
end
