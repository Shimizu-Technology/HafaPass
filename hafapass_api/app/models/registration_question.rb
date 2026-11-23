# frozen_string_literal: true

class RegistrationQuestion < ApplicationRecord
  include OperationalAuditable

  audits_operations :registration_question,
    fields: %w[event_id kind required active position scope show_on_scanner],
    observe: %w[prompt options help_text ticket_type_ids validation_rules]

  OPTION_KINDS = %w[selection multi_select].freeze
  NUMBER_LIMIT = 1_000_000_000
  # Longest numeric answer accepted before it is parsed at all.
  NUMBER_TEXT_LIMIT = 24
  VALIDATION_RULE_KEYS = %w[min max integer].freeze
  EMAIL_FORMAT = URI::MailTo::EMAIL_REGEXP
  PHONE_FORMAT = /\A\+?[0-9().\-\s]+\z/

  belongs_to :event
  has_many :registration_responses, dependent: :restrict_with_error

  # A checkbox is an affirmative acknowledgement or opt-in ("I confirm I am an
  # FD alumnus"): required means it must be checked. A yes/no choice is a
  # selection question with the options ["Yes", "No"].
  enum :kind, { short_text: 0, long_text: 1, selection: 2, checkbox: 3, number: 4, phone: 5, email: 6, multi_select: 7 }, validate: true
  # "order" questions are asked once per checkout; "ticket" questions once for
  # every ticket they apply to.
  enum :scope, { order: 0, ticket: 1 }, prefix: true, validate: true

  before_validation :normalize_ticket_type_ids
  before_validation :normalize_validation_rules
  # Prepended so the pause instruction wins over the generic restrict error
  # when a question has both issued and pending answers.
  before_destroy :ensure_not_awaiting_payment, prepend: true

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
    # Choices must match a stored option exactly; they are never trimmed.
    return value.is_a?(String) && options.include?(value) if selection?
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
    return value if selection? || multi_select?
    return value.strip if value.is_a?(String) && !number?
    return value unless number?

    number = BigDecimal(value.to_s.strip)
    number.frac.zero? ? number.to_i : number.to_f
  end

  def blank_answer?(value)
    value.nil? || value == [] || (value.is_a?(String) && value.strip.empty?)
  end

  def integer_only?
    validation_rules["integer"] == true
  end

  # Pending orders may hold order-scoped responses directly or ticket-scoped
  # answers in order_items.metadata until payment completes; deleting the
  # question then would drop them or break checkout.
  def referenced_by_pending_checkout?
    return false unless persisted?

    pending_status = Order.statuses.fetch("pending")
    registration_responses.joins(:order).where(orders: { event_id: event_id, status: pending_status }).exists? ||
      OrderItem.joins(:order).where(orders: { event_id: event_id, status: pending_status })
        .where("order_items.metadata @> ?", { "attendees" => [{ "answers" => [{ "question_id" => id }] }] }.to_json)
        .exists?
  end

  private

  def ensure_not_awaiting_payment
    return unless referenced_by_pending_checkout?

    errors.add(:base, "Buyers have answered this question on an order still waiting for payment. Pause the question instead of deleting it.")
    throw(:abort)
  end

  def valid_multi_select?(value)
    value.is_a?(Array) && value.all?(String) && value.uniq.length == value.length && (value - options).empty?
  end

  def valid_number?(value)
    text = value.is_a?(String) ? value.strip : value.to_s
    return false if text.length > NUMBER_TEXT_LIMIT

    number = case value
    when Integer then BigDecimal(value)
    when Float then value.finite? ? BigDecimal(text) : nil
    when String then text.match?(/\A-?\d+(\.\d+)?\z/) ? BigDecimal(text) : nil
    end
    return false if number.nil? || number.abs > NUMBER_LIMIT
    return false if integer_only? && !number.frac.zero?

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

  # Integer IDs (or their decimal strings) are sorted and deduplicated. Any
  # other item is left in place so validation rejects the list instead of
  # silently widening the question to every ticket type.
  def normalize_ticket_type_ids
    return unless ticket_type_ids.is_a?(Array)

    ids = ticket_type_ids.map { |id| id.is_a?(Integer) ? id : (id.is_a?(String) && id.match?(/\A\d+\z/) ? id.to_i : id) }
    self.ticket_type_ids = ids.all? { |id| id.is_a?(Integer) && id.positive? } ? ids.uniq.sort : ids
  end

  def normalize_validation_rules
    self.validation_rules = {} if validation_rules.blank?
    return unless validation_rules.is_a?(Hash)

    self.validation_rules = validation_rules.to_h.stringify_keys.to_h do |key, value|
      value = value.strip.to_i if value.is_a?(String) && value.strip.match?(/\A-?\d+\z/)
      value = ActiveModel::Type::Boolean.new.cast(value) if key == "integer" && %w[true false].include?(value.to_s)
      [key, value]
    end.compact
    validation_rules.delete("integer") if validation_rules["integer"] == false
  end

  # Only ticket types added by this change are checked, so a since-deleted
  # ticket type never blocks editing the rest of the question.
  def ticket_types_belong_to_event
    unless ticket_type_ids.is_a?(Array) && ticket_type_ids.all? { |id| id.is_a?(Integer) && id.positive? }
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
    unknown = validation_rules.keys - VALIDATION_RULE_KEYS
    errors.add(:validation_rules, "only support min, max and integer") if unknown.any?
    if validation_rules.key?("integer") && validation_rules["integer"] != true
      errors.add(:validation_rules, "integer must be true or false")
    end
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
