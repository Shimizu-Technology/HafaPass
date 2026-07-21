# frozen_string_literal: true

class CatalogFulfillment < ApplicationRecord
  belongs_to :order_item
  belongs_to :fulfilled_by_user, class_name: "User", optional: true

  enum :status, { pending: 0, fulfilled: 1, cancelled: 2 }

  validates :order_item_id, uniqueness: true
  validate :catalog_order_item

  def fulfill!(user:, at: Time.current)
    with_lock do
      return false if fulfilled?
      raise ActiveRecord::RecordInvalid, self if cancelled?

      update!(status: :fulfilled, fulfilled_at: at, fulfilled_by_user: user)
      true
    end
  end

  def cancel!
    update!(status: :cancelled) if pending?
  end

  private

  def catalog_order_item
    errors.add(:order_item, "must be a fulfillable catalog item") if order_item&.item_ticket? || order_item&.item_donation?
  end
end
