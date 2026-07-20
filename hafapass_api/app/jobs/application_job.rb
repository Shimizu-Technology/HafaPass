class ApplicationJob < ActiveJob::Base
  # Jobs that reference newly committed records must never race the transaction
  # that created them (checkout, guest-list redemption, refunds, and waitlists).
  self.enqueue_after_transaction_commit = true

  # Automatically retry jobs that encountered a deadlock
  retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

  # Most jobs are safe to ignore if the underlying records are no longer available
  discard_on ActiveJob::DeserializationError

  # Default queue
  queue_as :default

  around_perform do |job, block|
    Sentry.with_scope do |scope|
      scope.set_tags(
        job_class: job.class.name,
        job_id: job.job_id,
        queue: job.queue_name
      )
      block.call
    end
  end
end
