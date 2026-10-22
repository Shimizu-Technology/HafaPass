# frozen_string_literal: true

class SweepWaitlistDeliveriesJob < ApplicationJob
  queue_as :low

  def perform
    MessageDelivery.where(template: %w[waitlist_notification waitlist_offer], status: [:suppressed, :failed, :bounced, :complained], reconciled_at: nil)
      .order(:created_at, :id).limit(500).each { |delivery| WaitlistDelivery.reconcile_failure!(delivery) }
  end
end
