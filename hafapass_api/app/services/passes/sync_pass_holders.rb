# frozen_string_literal: true

module Passes
  class SyncPassHolders
    class SyncError < StandardError; end
    class AuthorizationError < StandardError; end

    Result = Data.define(:ticket_type, :parent_ticket_count, :issued_ticket_count, :included_event_ids)

    def self.call(**)
      new(**).call
    end

    def initialize(ticket_type:, actor:, request: nil)
      @ticket_type = ticket_type
      @actor = actor
      @request = request
    end

    def call
      result = nil
      Passes::Locking.with_lock_retry do
        Ticket.transaction do
          organization = ticket_type.event.organization
          # Rank 1: organization FOR NO KEY UPDATE
          organization.lock!("FOR NO KEY UPDATE")

          ticket_type.reload
          included_events = ticket_type.ticket_type_included_events.reload.includes(:included_event).map(&:included_event)
          raise SyncError, "Ticket type is not a multi-night pass" unless ticket_type.pass? && included_events.any?

          # Rank 2: all involved events in ascending event.id order (FOR NO KEY UPDATE)
          locked_events = Passes::Locking.lock_events!([ticket_type.event, *included_events])
          current_included_ids = ticket_type.ticket_type_included_events.pluck(:included_event_id)
          if (current_included_ids - locked_events.map(&:id)).any?
            raise Passes::Locking::LockSetChanged, "Pass included events changed while acquiring event locks"
          end

          ticket_type.reload
          included_events = ticket_type.ticket_type_included_events.reload.includes(:included_event).map(&:included_event)
          raise SyncError, "Ticket type is not a multi-night pass" unless ticket_type.pass? && included_events.any?

          if actor && included_events.any? { |ev|
            !OrganizationAuthorization.allowed?(user: actor, organization: organization, permission: :manage_inventory, event: ev)
          }
            raise AuthorizationError, "You do not have permission to perform this action"
          end

        # Rank 3: active pass orders sorted by id
        candidate_order_ids = Ticket.joins(:order)
          .where(ticket_type_id: ticket_type.id, parent_ticket_id: nil, status: :issued)
          .where(orders: { status: Order.statuses.values_at("completed", "partially_refunded") })
          .distinct
          .pluck(:order_id)
          .sort
        orders_by_id = Order.where(id: candidate_order_ids).order(:id).lock.index_by(&:id)
        active_order_ids = orders_by_id.values.select { |o| o.completed? || o.partially_refunded? }.map(&:id)

        # Rank 3a: active (issued) parent tickets sorted by id
        parent_tickets = Ticket.where(
          ticket_type_id: ticket_type.id,
          parent_ticket_id: nil,
          status: :issued,
          order_id: active_order_ids
        ).order(:id).lock.to_a

        existing_pairs = if parent_tickets.any?
          Ticket.where(parent_ticket_id: parent_tickets.map(&:id), event_id: included_events.map(&:id))
            .pluck(:parent_ticket_id, :event_id)
            .to_set
        else
          Set.new
        end

        missing_by_event = Hash.new { |hash, key| hash[key] = [] }
        parent_tickets.each do |parent|
          included_events.each do |included_event|
            next if existing_pairs.include?([parent.id, included_event.id])

            missing_by_event[included_event] << parent
          end
        end

        now = Time.current
        missing_by_event.each do |included_event, missing_parents|
          next if missing_parents.empty? || included_event.max_capacity.blank?

          remaining = EventCapacity.remaining_for(included_event, at: now)
          if remaining < missing_parents.length
            raise SyncError,
              "Insufficient capacity on #{included_event.title}: needs #{missing_parents.length} additional pass tickets, only #{remaining} remaining"
          end
        end

        issued_count = 0
        parent_tickets.each do |parent|
          created = Passes::Issuance.call(
            order: orders_by_id.fetch(parent.order_id),
            parent_ticket: parent,
            included_events: included_events
          )
          issued_count += created.length
        end

        AuditLogger.record!(
          action: "ticket_type.pass_holders_synced",
          auditable: ticket_type,
          actor: actor,
          organization: organization,
          event: ticket_type.event,
          outcome: "succeeded",
          metadata: {
            ticket_type_id: ticket_type.id,
            parent_ticket_count: parent_tickets.length,
            issued_ticket_count: issued_count,
            included_event_count: included_events.length
          },
          request: request
        )

          result = Result.new(
            ticket_type: ticket_type,
            parent_ticket_count: parent_tickets.length,
            issued_ticket_count: issued_count,
            included_event_ids: included_events.map(&:id)
          )
        end
      end
      result
    end

    private

    attr_reader :ticket_type, :actor, :request
  end
end
