# frozen_string_literal: true

class WaiverAcceptance < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :order
  belongs_to :event_waiver

  validates :version, :content_digest, :accepted_at, presence: true
  validates :event_waiver_id, uniqueness: { scope: :order_id }
end
