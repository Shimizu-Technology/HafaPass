# frozen_string_literal: true

# Read-only, platform-admin drilldown. Keep readiness counts and review rows on
# these exact scopes; provider receipt presence does not imply delivery failure.
class OperationalReview
  PAGE_SIZE = 50
  CATEGORIES = %w[failed_messages_last_hour stale_message_events failed_payment_webhooks
    open_reconciliation_exceptions unknown_card_present_results].freeze

  def initialize(now: Time.current)
    @now = now
  end

  def signals
    { ready: true, status: "observable" }.merge(scopes.transform_values(&:count).transform_keys(&:to_sym))
  end

  def call(category: nil, page: 1)
    # One database snapshot keeps category totals and paged rows together even
    # while the worker processes receipts. An existing caller owns its transaction
    # (including transactional specs); ordinary HTTP reads open their own snapshot.
    if ApplicationRecord.connection.transaction_open?
      review(category: category, page: page)
    else
      ApplicationRecord.transaction(isolation: :repeatable_read) { review(category: category, page: page) }
    end
  end

  private

  def review(category:, page:)
    counts = signals
    category = CATEGORIES.find { |key| counts.fetch(key.to_sym).positive? } || CATEGORIES.first if category.blank?
    raise ArgumentError, "Unknown operational category" unless CATEGORIES.include?(category)

    page = [page.to_s.to_i, 1].max
    total = counts.fetch(category.to_sym)
    items = scopes.fetch(category).order(:id).offset((page - 1) * PAGE_SIZE).limit(PAGE_SIZE)
    {
      signals: counts, checked_at: @now.iso8601, category: category,
      items: items.map { |record| serialize(record) },
      meta: { page: page, per_page: PAGE_SIZE, total_count: total, total_pages: (total.to_f / PAGE_SIZE).ceil }
    }
  end

  def scopes
    @scopes ||= {
      "failed_messages_last_hour" => MessageDelivery.failed.where(updated_at: (@now - 1.hour)..),
      "stale_message_events" => MessageProviderEvent.where(processed_at: nil).where("received_at < ?", @now - 5.minutes),
      "failed_payment_webhooks" => WebhookEvent.failed,
      "open_reconciliation_exceptions" => ReconciliationException.open,
      "unknown_card_present_results" => CardPresentPaymentAttempt.status_result_unknown
    }
  end

  def serialize(record)
    case record
    when MessageProviderEvent
      {
        id: record.id, provider: safe_provider(record.provider),
        event_type: MessageProviderEventProcessor::STATUS_BY_EVENT.key?(record.event_type) ? record.event_type : "other",
        received_at: record.received_at, occurred_at: record.occurred_at,
        delivery_id: record.message_delivery_id, processing_error: record.processing_error.present?,
        review_state: record.processing_error.present? ? "processing_error" :
          (record.message_delivery_id ? "awaiting_processing" : "no_linked_delivery")
      }
    when MessageDelivery
      { id: record.id, status: record.status, updated_at: record.updated_at }
    when WebhookEvent
      { id: record.id, status: record.status, provider: safe_provider(record.provider), updated_at: record.updated_at }
    when ReconciliationException
      { id: record.id, status: record.status, order_id: record.order_id, created_at: record.created_at }
    when CardPresentPaymentAttempt
      { id: record.id, status: record.status, event_id: record.event_id, order_id: record.order_id,
        initiated_at: record.initiated_at }
    end
  end

  # Provider-controlled strings, error text, payloads and external identifiers
  # can contain personal data. Only fixed vocabulary and local IDs leave here.
  def safe_provider(value)
    %w[resend stripe clover simulated].include?(value) ? value : "other"
  end
end
