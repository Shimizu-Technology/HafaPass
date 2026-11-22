# frozen_string_literal: true

class RegistrationQuestion < ApplicationRecord
  include OperationalAuditable

  audits_operations :registration_question,
    fields: %w[event_id kind required active position scope show_on_scanner],
    observe: %w[prompt options help_text ticket_type_ids validation_rules]

  OPTION_KINDS = %w[selection multi_select].freeze
  NUMBER_LIMIT = 1_000_000_000
  EMAIL_FORMAT = URI::MailTo::EMAIL_REGEXP
  PHONE_FORMAT = /\A\+?[0-9().\-\s]+\z/

  belongs_to :event
  has_many :registration_responses, dependent: :restrict_with_error

  enum :kind, { short_text: 0, long_text: 1, selection: 2, checkbox: 3, number: 4, phone: 5, email: 6, multi_select: 7 }, validate: true
  # "order" questions are asked once per checkout; "ticket" questions once for
  # every ticket they apply to.
  enum :scope, { order: 0, ticket: 1 }, prefix: true, validate: true

  before_validation :normalize_ticket_type_ids
  before_validation :normalize_validation_rules

  validates :prompt, presence: true, length: { maximum: 500 }
  validates :help_text, length: { maximum: 250 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :show_on_scanner, inclusion: { in: [true, false] }
  validate :selection_has_options
  validate :ticket_types_belong_to_event
  validate :validation_rules_supported

  scope :published, -> { where(active: true).order(:position, :id) }

  # Empty ticket_type_ids means the question applies to every ticket type.
  def applies_to_ticket_type?(ticket_type_id)
    ticket_type_ids.blank? || ticket_type_ids.include?(ticket_type_id.to_i)
  end

  def applies_to_any_ticket_type?(ticket_type_ids)
    ticket_type_ids.any? { |id| applies_to_ticket_type?(id) }
  end

  def valid_answer?(value, enforce_required: true)
    return !(enforce_required && required?) if blank_answer?(value)
    return options.include?(value.to_s) if selection?
    return value == true || (value == false && !(enforce_required && required?)) if checkbox?
    return valid_multi_select?(value) if multi_select?
    return valid_number?(value) if number?
    return value.is_a?(String) && value.strip.length <= 254 && value.strip.match?(EMAIL_FORMAT) if email?
    return valid_phone?(value) if phone?

    value.is_a?(String) && value.length <= (long_text? ? 4000 : 500)
  end

  # The stored form of an answer already checked by valid_answer?.
  def normalized_answer(value)
    return value.strip.downcase if email? && value.is_a?(String)
    return value.strip if value.is_a?(String) && !number?
    return value unless number?

    number = BigDecimal(value.to_s.strip)
    number.frac.zero? ? number.to_i : number.to_f
  end

  def blank_answer?(value)
    value.nil? || value == [] || (value.is_a?(String) && value.strip.empty?)
  end

  private

  def valid_multi_select?(value)
    value.is_a?(Array) && value.all?(String) && value.uniq.length == value.length && (value - options).empty?
  end

  def valid_number?(value)
    number = case value
    when Integer then BigDecimal(value)
    when Float then value.finite? ? BigDecimal(value.to_s) : nil
    when String then value.strip.match?(/\A-?\d+(\.\d+)?\z/) ? BigDecimal(value.strip) : nil
    end
    return false if number.nil? || number.abs > NUMBER_LIMIT

    minimum = validation_rules["min"]
    maximum = validation_rules["max"]
    (minimum.nil? || number >= minimum) && (maximum.nil? || number <= maximum)
  end

  def valid_phone?(value)
    return false unless value.is_a?(String) && value.strip.length <= 40 && value.strip.match?(PHONE_FORMAT)

    value.count("0-9").between?(7, 15)
  end

  def selection_has_options
    if OPTION_KINDS.include?(kind)
      unless options.is_a?(Array) && options.any? && options.all? { |option| option.is_a?(String) && option.strip.present? }
        errors.add(:options, "must include at least one choice")
      end
      errors.add(:options, "must not repeat a choice") if options.is_a?(Array) && options.uniq.length != options.length
    elsif options.present?
      errors.add(:options, "are only supported for selection and multiple choice questions")
    end
  end

  def normalize_ticket_type_ids
    return unless ticket_type_ids.is_a?(Array)

    self.ticket_type_ids = ticket_type_ids.filter_map { |id| Integer(id.to_s, exception: false) }.uniq.sort
  end

  def normalize_validation_rules
    self.validation_rules = {} if validation_rules.blank?
    return unless validation_rules.is_a?(Hash)

    self.validation_rules = validation_rules.to_h.stringify_keys.transform_values do |value|
      value.is_a?(String) && value.strip.match?(/\A-?\d+\z/) ? value.strip.to_i : value
    end.compact
  end

  # Only ticket types added by this change are checked, so a since-deleted
  # ticket type never blocks editing the rest of the question.
  def ticket_types_belong_to_event
    unless ticket_type_ids.is_a?(Array)
      errors.add(:ticket_type_ids, "must be a list of ticket types")
      return
    end
    added = ticket_type_ids - Array(ticket_type_ids_in_database)
    return if added.empty?

    known = event ? event.ticket_types.where(id: added).pluck(:id) : []
    errors.add(:ticket_type_ids, "must belong to this event") unless (added - known).empty?
  end

  def validation_rules_supported
    unless validation_rules.is_a?(Hash)
      errors.add(:validation_rules, "must be an object")
      return
    end
    return if validation_rules.empty?

    unless number?
      errors.add(:validation_rules, "are only supported for number questions")
      return
    end
    unknown = validation_rules.keys - %w[min max]
    errors.add(:validation_rules, "only support min and max") if unknown.any?
    bounds = validation_rules.slice("min", "max")
    unless bounds.values.all? { |value| value.is_a?(Integer) && value.abs <= NUMBER_LIMIT }
      errors.add(:validation_rules, "min and max must be whole numbers")
      return
    end
    if bounds["min"] && bounds["max"] && bounds["min"] > bounds["max"]
      errors.add(:validation_rules, "min must not be greater than max")
    end
  end
end
