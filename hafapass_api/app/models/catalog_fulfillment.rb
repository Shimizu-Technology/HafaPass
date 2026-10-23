# frozen_string_literal: true

class CatalogFulfillment < ApplicationRecord
  include OperationalAuditable

  audits_operations :catalog_fulfillment,
    fields: %w[order_item_id status fulfilled_at]

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

  def operational_audit_event
    order_item.order.event
  end

  def operational_audit_actor(operation)
    return fulfilled_by_user || super if operation == :update && saved_change_to_status? && fulfilled?

    super
  end

  def operational_audit_action(operation)
    return "catalog_fulfillment.#{status}" if operation == :update && saved_change_to_status?

    super
  end

  def catalog_order_item
    errors.add(:order_item, "must be a fulfillable catalog item") if order_item&.item_ticket? || order_item&.item_donation?
  end
end
