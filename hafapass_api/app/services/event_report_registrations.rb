# frozen_string_literal: true

# Answers are snapshots. A checkout answer counts once per eligible order,
# while a ticket answer counts once per eligible ticket (or its parent pass).
class EventReportRegistrations
  TEXT_KINDS = %w[short_text long_text email phone].freeze
  TEXT_BUCKET_LIMIT = 25
  ANSWER_SQL = <<~SQL.squish.freeze
    CASE WHEN jsonb_typeof(registration_responses.answer) = 'object'
         THEN registration_responses.answer->'value'
         ELSE registration_responses.answer END
  SQL
  TEXT_SQL = "regexp_replace((#{ANSWER_SQL}) #>> '{}', '^[[:space:]]+|[[:space:]]+$', '', 'g')".freeze

  def self.value(raw)
    raw.is_a?(Hash) ? raw["value"] : raw
  end

  def self.display(value)
    case value
    when true then "Yes"
    when false then "No"
    when Array then value.join(", ")
    else value.to_s
    end
  end

  class Inline
    def initialize(records)
      order_ids = records.map { |record| record.is_a?(Order) ? record.id : record.order_id }.uniq
      @responses = RegistrationResponse.where(order_id: order_ids, retention_anonymized_at: nil)
        .joins(:order, :registration_question)
        .where("registration_questions.event_id = orders.event_id")
        .order(:id)
        .pluck(:order_id, :ticket_id, :registration_question_id, :prompt_snapshot, :answer, "registration_questions.ticket_type_ids")
        .group_by(&:first)
      @by_ticket = @responses.transform_values { |rows| rows.group_by { |row| row[1] } }
    end

    def for_order(order)
      format(@responses.fetch(order.id, []))
    end

    def for_ticket(ticket)
      rows = @by_ticket.fetch(ticket.order_id, {})
      order_answers = rows.fetch(nil, []).select { |row| row.last.empty? || row.last.include?(ticket.ticket_type_id) }
      format(order_answers + rows.fetch(ticket.parent_ticket_id || ticket.id, []))
    end

    private

    def format(rows)
      rows.filter_map do |_, ticket_id, question_id, prompt, raw, _|
        value = EventReportRegistrations.value(raw)
        { question_id: question_id, prompt: prompt, value: value, ticket_id: ticket_id } unless value.nil?
      end
    end
  end

  def self.filter(tickets, question, answer)
    applies = question.ticket_type_ids.presence
    order_answer = "registration_responses.ticket_id IS NULL"
    if applies
      order_answer = ActiveRecord::Base.sanitize_sql_array([
        "(#{order_answer} AND tickets.ticket_type_id IN (?))", applies
      ])
    end

    matches = question.registration_responses.where(retention_anonymized_at: nil)
      .where("registration_responses.order_id = tickets.order_id")
      .where("(#{order_answer} OR registration_responses.ticket_id = COALESCE(tickets.parent_ticket_id, tickets.id))")
    tickets.where(answer_match(matches, question, answer).arel.exists)
  end

  def self.answer_match(matches, question, answer)
    case question.kind
    when "selection", "multi_select"
      # A historical answer may use the prior single/multiple-choice shape.
      matches.where("(#{ANSWER_SQL}) = CAST(? AS jsonb) OR (#{ANSWER_SQL}) @> CAST(? AS jsonb)",
        answer.to_json, [answer].to_json)
    when "checkbox"
      case answer.downcase
      when "true", "yes" then matches.where("(#{ANSWER_SQL}) = 'true'::jsonb")
      when "false", "no" then matches.where("(#{ANSWER_SQL}) = 'false'::jsonb")
      else matches.none
      end
    when "number"
      number = number_value(answer)
      number.nil? ? matches.none : matches.where(<<~SQL.squish, "^-?[0-9]+([.][0-9]+)?$", number.to_s("F"))
        CASE WHEN #{TEXT_SQL} ~ ?
          THEN CAST(#{TEXT_SQL} AS numeric) END = CAST(? AS numeric)
      SQL
    when *TEXT_KINDS
      matches.where("jsonb_typeof(#{ANSWER_SQL}) = 'string' AND lower(#{TEXT_SQL}) = lower(?)", answer.strip)
    else
      matches.where("(#{ANSWER_SQL}) = CAST(? AS jsonb)", answer.to_json)
    end
  end

  def self.number_value(value)
    return unless (value.is_a?(Numeric) || value.is_a?(String)) && value.to_s.bytesize <= RegistrationQuestion::NUMBER_TEXT_LIMIT

    number = BigDecimal(value.to_s, exception: false)
    # Values in the URL may use scientific notation. Keep conversion to a
    # plain decimal inside the range that checkout could have stored.
    if number&.finite? && number.exponent.between?(-RegistrationQuestion::NUMBER_TEXT_LIMIT, 10) &&
        number.abs <= RegistrationQuestion::NUMBER_LIMIT
      number
    end
  end

  def initialize(event:, tickets:)
    @event = event
    @tickets = tickets
  end

  def questions
    @questions ||= begin
      answered = RegistrationResponse.where(order_id: @event.orders.select(:id)).select(:registration_question_id)
      scope = @event.registration_questions
      scope.where(active: true).or(scope.where(id: answered)).order(:position, :id).to_a
    end
  end

  def demographics
    return [] if questions.empty?

    questions.map do |question|
      eligible = eligible_respondents(question)
      counts, labels, answered = distribution(question)
      buckets = buckets_for(question, counts, labels, answered)
      other_count = 0
      if TEXT_KINDS.include?(question.kind)
        other_count = buckets.drop(TEXT_BUCKET_LIMIT).sum { |bucket| bucket[:count] }
        buckets = buckets.take(TEXT_BUCKET_LIMIT)
      end
      question.as_json(only: [:prompt, :kind, :scope, :ticket_type_ids]).symbolize_keys.merge(
        question_id: question.id, total_responses: answered, blank_or_unanswered_count: [eligible - answered, 0].max,
        buckets: buckets, other_count: other_count
      )
    end
  end

  private

  def ticket_rows
    @ticket_rows ||= @tickets.pluck(:id, :parent_ticket_id, :order_id, :ticket_type_id)
  end

  def ticket_types_by_order
    @ticket_types_by_order ||= ticket_rows.each_with_object(Hash.new { |hash, id| hash[id] = Set.new }) do |row, types|
      types[row[2]].add(row.last)
    end
  end

  def ticket_counts_by_type
    @ticket_counts_by_type ||= ticket_rows.group_by(&:last)
      .transform_values { |rows| rows.map { |id, parent_id, *| parent_id || id }.uniq.length }
  end

  def eligible_respondents(question)
    if question.scope_ticket?
      ticket_counts_by_type.sum { |id, count| question.applies_to_ticket_type?(id) ? count : 0 }
    elsif question.ticket_type_ids.empty?
      ticket_types_by_order.length
    else
      ticket_types_by_order.count { |_id, types| question.applies_to_any_ticket_type?(types) }
    end
  end

  def response_rows
    @response_rows ||= begin
      responses = RegistrationResponse.where(registration_question_id: questions.map(&:id), retention_anonymized_at: nil)
      order_answers = responses.where(ticket_id: nil, order_id: @tickets.select(:order_id))
      ticket_answers = responses.where(ticket_id: @tickets.select("COALESCE(tickets.parent_ticket_id, tickets.id)"),
        order_id: @tickets.select(:order_id))
      order_answers.or(ticket_answers).pluck(:registration_question_id, :ticket_id, :order_id, :answer).group_by(&:first)
    end
  end

  def distribution(question)
    counts = Hash.new(0)
    labels = {}
    answered = 0
    response_rows.fetch(question.id, []).each do |_, ticket_id, order_id, raw|
      next if ticket_id.nil? && !question.applies_to_any_ticket_type?(ticket_types_by_order.fetch(order_id))

      values = answer_values(question, self.class.value(raw))
      next if values.empty?

      answered += 1
      values.uniq.each do |value, label|
        labels[value] = [labels[value], label].compact.min
        counts[value] += 1
      end
    end
    [counts, labels, answered]
  end

  def answer_values(question, value)
    return [] if question.blank_answer?(value)

    case question.kind
    when "checkbox" then [true, false].include?(value) ? [[value, self.class.display(value)]] : []
    when "number"
      number = self.class.number_value(value)
      number ? [[number, number.frac.zero? ? number.to_i.to_s : number.to_s("F")]] : []
    when "selection", "multi_select" then Array(value).grep(String).map { |choice| [choice, choice] }
    else
      value.is_a?(String) ? [[value.strip.downcase, value.strip]] : []
    end
  end

  def buckets_for(question, counts, labels, answered)
    defaults = case question.kind
    when "selection", "multi_select" then question.options.index_with(&:itself)
    when "checkbox" then { true => "Yes", false => "No" }
    else {}
    end
    labels.reverse_merge(defaults).sort_by do |value, label|
      [-counts[value], question.number? ? value : label]
    end.map do |value, label|
      count = counts[value]
      { value: question.number? ? (value.frac.zero? ? value.to_i : value.to_f) : value,
        label: label, count: count, percentage: EventReportingService.percentage(count, answered) }
    end
  end
end
