# frozen_string_literal: true

class InventoryHold < ApplicationRecord
  include PublicEventCacheBuster

  # Released or expired holds return inventory to the public pages.
  busts_public_event_cache on: :update, condition: -> { saved_change_to_status? && (released? || expired?) }

  belongs_to :order
  belongs_to :order_item
  belongs_to :event
  belongs_to :ticket_type
  belongs_to :pricing_tier, optional: true

  enum :status, { active: 0, consumed: 1, released: 2, expired: 3 }

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :expires_at, presence: true
  validates :order_item_id, uniqueness: true

  scope :current, -> { active.where("inventory_holds.expires_at > ?", Time.current) }
  scope :due, -> { active.where(expires_at: ..Time.current) }

  def consume!(at: Time.current)
    update!(status: :consumed, consumed_at: at) if active?
  end

  def release!(reason:, at: Time.current, expired: false)
    return unless active?

    update!(
      status: expired ? :expired : :released,
      released_at: at,
      release_reason: reason
    )
  end
end
