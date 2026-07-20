# frozen_string_literal: true

class SupportNote < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :author_user, class_name: "User", inverse_of: :support_notes
  belongs_to :order, optional: true
  belongs_to :ticket, optional: true
  belongs_to :event, optional: true

  validates :body, presence: true, length: { maximum: 4000 }
  validate :subject_present

  private

  def subject_present
    errors.add(:base, "Order, ticket, or event is required") if order_id.blank? && ticket_id.blank? && event_id.blank?
  end
end
