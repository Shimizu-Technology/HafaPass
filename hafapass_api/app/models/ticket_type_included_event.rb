# frozen_string_literal: true

class TicketTypeIncludedEvent < ApplicationRecord
  belongs_to :ticket_type
  belongs_to :included_event, class_name: "Event"

  validates :included_event_id, uniqueness: { scope: :ticket_type_id }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :included_event_belongs_to_same_organization
  validate :included_event_is_not_parent_event
  validate :events_are_general_admission
  validate :no_nested_passes

  before_destroy :ensure_removable
  after_create :sync_ticket_type_pass_flag
  after_destroy :sync_ticket_type_pass_flag

  private

  def included_event_belongs_to_same_organization
    return unless ticket_type&.event && included_event
    return if included_event.organization_id == ticket_type.event.organization_id

    errors.add(:included_event, "must belong to the same organization as the pass event")
  end

  def included_event_is_not_parent_event
    return unless ticket_type && included_event_id.present?
    return if included_event_id != ticket_type.event_id

    errors.add(:included_event, "cannot be the pass event itself")
  end

  def events_are_general_admission
    return unless ticket_type&.event && included_event

    if ticket_type.event.event_seating_configuration.present?
      errors.add(:ticket_type, "cannot be a multi-night pass on an event with assigned seating")
    end
    if included_event.event_seating_configuration.present?
      errors.add(:included_event, "cannot use assigned seating when included in a multi-night pass")
    end
  end

  def no_nested_passes
    return unless ticket_type&.event && included_event

    if included_event.ticket_types.where(is_pass: true).exists? ||
        TicketTypeIncludedEvent.joins(:ticket_type).where(ticket_types: { event_id: included_event_id }).exists?
      errors.add(:included_event, "cannot itself contain multi-night pass ticket types")
    end

    if TicketTypeIncludedEvent.where(included_event_id: ticket_type.event_id).exists?
      errors.add(:ticket_type, "belongs to an event that is already included in another multi-night pass")
    end
  end

  def ensure_removable
    return unless ticket_type.quantity_sold.positive? || ticket_type.inventory_holds.current.exists?

    errors.add(:base, "Included events cannot be removed once passes have been sold or held")
    throw(:abort)
  end

  def sync_ticket_type_pass_flag
    return if ticket_type.destroyed?

    should_be_pass = ticket_type.ticket_type_included_events.exists?
    ticket_type.update_column(:is_pass, should_be_pass) if ticket_type.is_pass? != should_be_pass
  end
end
