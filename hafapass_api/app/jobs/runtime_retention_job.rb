# frozen_string_literal: true

class RuntimeRetentionJob < ApplicationJob
  queue_as :low

  def perform
    RuntimeThrottleBucket.where("expires_at < ?", 1.day.ago).delete_all
    RuntimeExecution.where("last_succeeded_at < ?", 7.days.ago).delete_all
    SolidQueue::Job.clear_finished_in_batches(finished_before: 1.day.ago) if RuntimeConfiguration.solid_queue?
  end
end
