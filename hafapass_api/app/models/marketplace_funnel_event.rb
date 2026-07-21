# frozen_string_literal: true

class MarketplaceFunnelEvent < ApplicationRecord
  belongs_to :event
  belongs_to :distribution_link, optional: true
  belongs_to :event_referral, optional: true
  belongs_to :order, optional: true
  enum :stage, { landing: 0, event_view: 1, checkout_started: 2, purchase: 3 }
  validates :visitor_hash, :occurred_at, presence: true
  validates :source, :medium, :campaign, length: { maximum: 255 }, allow_blank: true
  validates :source, :medium, :campaign, format: { with: /\A[a-zA-Z0-9._-]+\z/ }, allow_blank: true
end
