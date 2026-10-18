# frozen_string_literal: true

class RuntimeRecoveryJob < ApplicationJob
  # These jobs are domain-idempotent or only retrieve provider evidence. Never
  # reinterpret an arbitrary failed charge/refund/payout as permission to POST.
  SAFE_INTERRUPTED_JOBS = %w[MessageDeliveryJob StripeProcessingFeeJob SweepPendingStripeFeesJob
    ExpireInventoryHoldsJob ExpireSeatHoldsJob EventReminderJob CommunicationCampaignJob
    PurgeMarketplaceAnalyticsJob RuntimeRetentionJob RuntimeRecoveryJob].freeze
  INTERRUPTED_ERRORS = %w[SolidQueue::Processes::ProcessPrunedError SolidQueue::Processes::ThreadTerminatedError
    SolidQueue::Processes::ProcessMissingError].freeze
  BATCH_SIZE = 50

  def perform
    return unless RuntimeConfiguration.solid_queue?

    SolidQueue::FailedExecution.joins(:job).where(solid_queue_jobs: { class_name: SAFE_INTERRUPTED_JOBS })
      .where("error::jsonb ->> 'exception_class' IN (?)", INTERRUPTED_ERRORS)
      .limit(BATCH_SIZE).each do |failure|
      failure.retry
    end

    MessageDelivery.where(status: [:queued, :failed], provider_id: [nil, ""])
      .where("attempts < 5 AND (send_lease_expires_at IS NULL OR send_lease_expires_at <= ?)", Time.current)
      .where("NOT ((provider_outcome_unknown OR (provider = 'resend' AND provider_attempted_at IS NULL AND attempts > 0)) " \
        "AND COALESCE(provider_attempted_at, created_at) <= ?)", MessageDelivery::PROVIDER_REPLAY_WINDOW.ago)
      .where(no_pending_job_sql("MessageDeliveryJob", "jsonb_build_array(message_deliveries.id)"))
      .order(:id).limit(BATCH_SIZE).each do |delivery|
      next if delivery.provider_replay_expired?

      enqueue_unless_pending(MessageDeliveryJob, delivery.id)
    end
    EventReminder.pending.where("remind_at <= ?", Time.current)
      .where(no_pending_job_sql("EventReminderJob", scheduled_arguments_sql("event_reminders", "remind_at")))
      .order(:id).limit(BATCH_SIZE).each do |reminder|
      enqueue_unless_pending(EventReminderJob, reminder.id, reminder.remind_at.utc.iso8601)
    end
    CommunicationCampaign.scheduled.where("scheduled_at <= ?", Time.current)
      .where(no_pending_job_sql("CommunicationCampaignJob", scheduled_arguments_sql("communication_campaigns", "scheduled_at")))
      .order(:id).limit(BATCH_SIZE).each do |campaign|
      enqueue_unless_pending(CommunicationCampaignJob, campaign.id, campaign.scheduled_at.utc.iso8601)
    end
    MessageProviderEvent.where(processed_at: nil)
      .joins("INNER JOIN message_deliveries ON message_deliveries.provider = message_provider_events.provider " \
        "AND message_deliveries.provider_id = message_provider_events.provider_message_id")
      .order("message_provider_events.id").limit(BATCH_SIZE).each do |receipt|
      delivery = MessageDelivery.find_by(provider: receipt.provider, provider_id: receipt.provider_message_id)
      MessageProviderEventProcessor.reconcile_for!(delivery) if delivery
    end
  end

  private

  def enqueue_unless_pending(job_class, *arguments)
    pending = SolidQueue::Job.where(finished_at: nil, class_name: job_class.name)
      .where("arguments::jsonb -> 'arguments' = ?::jsonb", arguments.to_json).exists?
    job_class.perform_later(*arguments) unless pending
  end

  def no_pending_job_sql(class_name, arguments_sql)
    "NOT EXISTS (SELECT 1 FROM solid_queue_jobs WHERE class_name = '#{class_name}' AND finished_at IS NULL " \
      "AND arguments::jsonb -> 'arguments' = #{arguments_sql})"
  end

  def scheduled_arguments_sql(table, timestamp)
    "jsonb_build_array(#{table}.id, to_char(#{table}.#{timestamp}, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'))"
  end
end
