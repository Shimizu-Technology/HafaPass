# frozen_string_literal: true

# The same allowlisted relation drives the list, CSV, and printable door list.
# Filtering happens before pagination. Exports snapshot at most 100,000 ordered
# IDs (a few megabytes), then load records in bounded batches.
class OrganizerSalesQuery
  class InvalidFilter < ArgumentError; end
  MAX_SNAPSHOT_IDS = 100_000

  SORTS = {
    "name" => ["COALESCE(NULLIF(tickets.attendee_name, ''), orders.buyer_name)", "orders.buyer_name"],
    "purchase_date" => ["COALESCE(orders.completed_at, orders.created_at)", "COALESCE(orders.completed_at, orders.created_at)"],
    "ticket_type" => ["ticket_types.name", "(SELECT MIN(tt.name) FROM tickets st JOIN ticket_types tt ON tt.id = st.ticket_type_id WHERE st.order_id = orders.id)"],
    "amount" => ["order_items.unit_price_cents - (order_items.discount_cents / NULLIF(order_items.quantity, 0))", "orders.total_cents"],
    "check_in_time" => ["tickets.checked_in_at", "(SELECT MAX(st.checked_in_at) FROM tickets st WHERE st.order_id = orders.id)"]
  }.freeze
  FILTER_KEYS = %w[search ticket_type status channel promo_code purchased_from purchased_to payment_environment sort direction view].freeze
  CHANNELS = %w[online box_office guest_list].freeze
  STATUSES = %w[paid refunded partially_refunded cancelled checked_in not_checked_in transferred issued].freeze

  attr_reader :filters, :view, :event

  def initialize(event:, params:, attendee_access:)
    @event = event
    @attendee_access = attendee_access
    input = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
    @filters = input.stringify_keys.slice(*FILTER_KEYS).transform_values { |value| value.to_s.strip }
      .reject { |_key, value| value.blank? }
    @view = filters.fetch("view", "tickets")
    validate!
  end

  def relation
    @relation ||= begin
      tickets = @event.tickets.joins(:order, :ticket_type).left_joins(:order_item)
      tickets = apply_filters(tickets)
      if view == "orders"
        orders = @event.orders.where(id: tickets.select(:order_id))
        orders = orders.order(Arel.sql(order_clause("orders.id", order_grain: true)))
        orders
      else
        tickets.order(Arel.sql(order_clause("tickets.id")))
      end
    end
  end

  def count
    relation.count
  end

  def page(number:, per_page:)
    relation.offset((number - 1) * per_page).limit(per_page)
  end

  def each_batch(size: 500, on_batch: nil)
    return enum_for(:each_batch, size: size, on_batch: on_batch) unless block_given?

    ids = relation.limit(MAX_SNAPSHOT_IDS + 1).pluck(:id)
    raise InvalidFilter, "Sales export is limited to #{MAX_SNAPSHOT_IDS} rows" if ids.length > MAX_SNAPSHOT_IDS

    ids.each_slice(size) do |slice|
      records = relation.except(:order).where(id: slice).includes(view == "orders" ?
        [:promo_code, :registration_responses, :support_notes, :order_items,
          { tickets: [:ticket_type, :ticket_transfers] }] :
        [:ticket_type, :order_item, :ticket_transfers, :support_notes,
          { order: [:promo_code, :registration_responses, :support_notes, :order_items] }]).index_by(&:id)
      batch = slice.filter_map { |id| records[id] }
      on_batch&.call(batch)
      batch.each { |record| yield record }
    end
  end

  private

  def validate!
    raise InvalidFilter, "Invalid view" unless %w[tickets orders].include?(view)
    raise InvalidFilter, "Invalid status" if filters["status"] && !STATUSES.include?(filters["status"])
    raise InvalidFilter, "Invalid channel" if filters["channel"] && !CHANNELS.include?(filters["channel"])
    raise InvalidFilter, "Invalid sort" if filters["sort"] && !SORTS.key?(filters["sort"])
    raise InvalidFilter, "Name sorting requires attendee access" if filters["sort"] == "name" && !@attendee_access
    raise InvalidFilter, "Invalid sort direction" if filters["direction"] && !%w[asc desc].include?(filters["direction"])
    raise InvalidFilter, "Invalid payment environment" if filters["payment_environment"] && !%w[live test all].include?(filters["payment_environment"])
    raise InvalidFilter, "Search is too long" if filters["search"]&.length.to_i > 200
    %w[purchased_from purchased_to].each { |key| Date.iso8601(filters[key]) if filters[key] }
    if filters["ticket_type"] && !@event.ticket_types.where(id: filters["ticket_type"]).exists?
      raise InvalidFilter, "Invalid ticket type"
    end
  rescue Date::Error
    raise InvalidFilter, "Invalid purchase date"
  end

  def apply_filters(tickets)
    tickets = tickets.where(ticket_type_id: filters["ticket_type"]) if filters["ticket_type"]
    tickets = apply_status(tickets)
    if filters["channel"]
      tickets = filters["channel"] == "online" ? tickets.where("orders.source IS NULL OR orders.source NOT IN (?)", %w[box_office guest_list]) :
        tickets.where(orders: { source: filters["channel"] })
    end
    if filters["promo_code"]
      codes = @event.promo_codes.where("LOWER(code) = ?", filters["promo_code"].downcase).select(:id)
      tickets = tickets.where(orders: { promo_code_id: codes })
    end
    zone = ActiveSupport::TimeZone[@event.timezone] || Time.zone
    if filters["purchased_from"]
      tickets = tickets.where("COALESCE(orders.completed_at, orders.created_at) >= ?", zone.parse(filters["purchased_from"]).utc)
    end
    if filters["purchased_to"]
      tickets = tickets.where("COALESCE(orders.completed_at, orders.created_at) < ?", (zone.parse(filters["purchased_to"]) + 1.day).utc)
    end
    environment = filters.fetch("payment_environment", "live")
    nonlive_orders = Payment.nonlive_stripe.select(:order_id)
    live_capture = Payment.live_or_legacy_capture.select(:order_id)
    tickets = tickets.where(orders: { id: nonlive_orders }).where.not(orders: { id: live_capture }) if environment == "test"
    tickets = tickets.where.not(orders: { id: nonlive_orders }).or(tickets.where(orders: { id: live_capture })) if environment == "live"
    if filters["search"]
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(filters['search'])}%"
      search_clause = if @attendee_access
        "tickets.attendee_name ILIKE :q OR tickets.attendee_email ILIKE :q OR " \
          "tickets.holder_email ILIKE :q OR orders.buyer_name ILIKE :q OR orders.buyer_email ILIKE :q OR " \
          "orders.reference ILIKE :q"
      else
        "orders.reference ILIKE :q"
      end
      tickets = tickets.where(search_clause, q: pattern)
    end
    tickets
  end

  def apply_status(tickets)
    return tickets unless filters["status"]

    OrganizerTicketSalesStatus.filter(tickets, filters["status"])
  end

  def order_clause(id_column, order_grain: false)
    column = SORTS.fetch(filters.fetch("sort", "purchase_date"))[order_grain ? 1 : 0]
    direction = filters.fetch("direction", "desc").upcase
    "#{column} #{direction} NULLS LAST, #{id_column} #{direction}"
  end
end
