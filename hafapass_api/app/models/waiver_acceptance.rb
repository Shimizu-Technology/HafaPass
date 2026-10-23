# frozen_string_literal: true

class WaiverAcceptance < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :order
  belongs_to :event_waiver

  validates :version, :content_digest, :accepted_at, presence: true
  validates :event_waiver_id, uniqueness: { scope: :order_id }
  after_create :audit_acceptance

  private

  def audit_acceptance
    AuditLogger.record!(action: "waiver.accepted", auditable: self, event: order.event, source: "system",
      after_data: { event_waiver_id: event_waiver_id, version: version, content_digest: content_digest, accepted_at: accepted_at },
      deduplication_key: "waiver-acceptance/#{id}")
  end
end
