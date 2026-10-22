# frozen_string_literal: true

class PrivacyRequest < ApplicationRecord
  KINDS = %w[access deletion].freeze
  STATUSES = %w[submitted verified completed partially_completed blocked].freeze

  belongs_to :user, optional: true
  belongs_to :order, optional: true
  belongs_to :verified_by, class_name: "User", optional: true
  belongs_to :executed_by, class_name: "User", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :requester_email, presence: true
  validate :subject_present

  def verified?
    verified_at.present?
  end

  private

  def subject_present
    errors.add(:base, "An account or verified guest order is required") unless user_id || order_id
  end
end
