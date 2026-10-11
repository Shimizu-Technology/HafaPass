# frozen_string_literal: true

Rails.application.config.after_initialize do
  SolidQueue::Processes::Base.prepend(Operations::SolidQueueProcessMetadata)
  SolidQueue.shutdown_timeout = 35.seconds
  SolidQueue.on_scheduler_start do
    if RuntimeConfiguration.solid_queue?
      [ExpireInventoryHoldsJob, ExpireSeatHoldsJob, RuntimeRecoveryJob, SweepPendingStripeFeesJob].each(&:perform_later)
    end
  end
end
