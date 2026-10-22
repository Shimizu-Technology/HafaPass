# frozen_string_literal: true

class SweepWaitlistDeliveriesJob < ApplicationJob
  queue_as :default

  def perform
    MessageDelivery.where(template: %w[waitlist_notification waitlist_offer], status: [:suppressed, :failed])
      .find_each { |delivery| WaitlistDelivery.reconcile_failure!(delivery) }
  end
end
