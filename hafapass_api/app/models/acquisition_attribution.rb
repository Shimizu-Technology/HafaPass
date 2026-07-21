# frozen_string_literal: true

class AcquisitionAttribution < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :order
  belongs_to :distribution_link, optional: true
  belongs_to :event_referral, optional: true
  validates :visitor_hash, :attributed_at, presence: true
  validates :order_id, uniqueness: true
  validates :source, :medium, :campaign, format: { with: /\A[a-zA-Z0-9._-]+\z/ }, allow_blank: true
end
