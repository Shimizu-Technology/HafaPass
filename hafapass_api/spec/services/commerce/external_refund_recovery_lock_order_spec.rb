# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# A1-R1 review finding 5: replay routes provider refunds into
# ExternalRefundRecovery, which locked the organization FOR UPDATE before the
# event. An ordinary order lifecycle step holds the event and then needs the
# organization FK KEY SHARE for its audit insert, so the two deadlocked. The
# recovery now takes the organization FOR NO KEY UPDATE like every refund
# writer (docs/LOCKING.md). Real PostgreSQL connections; the holder waits
# until the worker is blocked on the event before taking KEY SHARE.
RSpec.describe "External refund recovery lock order", :non_transactional do
  self.use_transactional_tests = false

  def clean_test_data
    unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")
      raise "Isolated test database required"
    end

    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE audit_logs, audit_write_failures, organizations, users, organizer_profiles, events, site_settings,
        webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  end

  before do
    clean_test_data
    allow(StripeService).to receive(:verify_payment_context!)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
  end

  after do
    clean_test_data
    expect(ActiveRecord::Base.connection_pool.stat[:busy]).to be <= 1
  end

  def fenced_capture
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
    ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry")
    [order, payment, capture]
  end

  it "deadlocks with the old organization FOR UPDATE prefix (the contention the review found)" do
    order, = fenced_capture
    outcome = race_against_event_audit(event: order.event, organization: order.event.organization) do
      Order.transaction do
        Organization.lock("FOR UPDATE").find(order.event.organization_id)
        Event.lock("FOR NO KEY UPDATE").find(order.event_id)
      end
      :committed
    end
    errors = outcome.values.grep(StandardError)
    expect(errors.map(&:class).map(&:name).join(" ") + errors.map(&:message).join(" "))
      .to match(/Deadlock|deadlock|LockWaitTimeout|lock timeout/)
  end

  it "records a provider refund while an order lifecycle step holds the event and writes its audit" do
    order, payment, capture = fenced_capture
    refund = OpenStruct.new(id: "re_lock_order", amount: 500, currency: "usd", payment_intent: payment.provider_payment_id,
      status: "succeeded", metadata: {})
    outcome = race_against_event_audit(event: order.event, organization: order.event.organization) do
      Commerce::ExternalRefundRecovery.ingest!(payment: Payment.find(payment.id), provider_refund: refund)
    end

    expect(outcome.fetch(:holder)).to eq(:committed)
    expect(outcome.fetch(:worker)).to be_a(Refund)
    expect(Refund.find_by!(provider_refund_id: "re_lock_order")).to be_succeeded
    expect(Commerce::BuyerReturnLedger.for(capture.reload).applied_cents).to eq(500)
  end
end
