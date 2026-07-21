# frozen_string_literal: true

class RegistrationQuestion < ApplicationRecord
  belongs_to :event
  has_many :registration_responses, dependent: :restrict_with_error

  enum :kind, { short_text: 0, long_text: 1, selection: 2, checkbox: 3 }

  validates :prompt, presence: true, length: { maximum: 500 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :selection_has_options

  scope :published, -> { where(active: true).order(:position, :id) }

  def valid_answer?(value)
    return false if required? && blank_answer?(value)
    return true if blank_answer?(value)
    return options.include?(value.to_s) if selection?
    return [true, false].include?(value) if checkbox?

    value.is_a?(String) && value.length <= (long_text? ? 4000 : 500)
  end

  private

  def blank_answer?(value)
    value.nil? || value == "" || value == []
  end

  def selection_has_options
    if selection?
      errors.add(:options, "must include at least one choice") unless options.is_a?(Array) && options.any?
    elsif options.present?
      errors.add(:options, "are only supported for selection questions")
    end
  end
end
