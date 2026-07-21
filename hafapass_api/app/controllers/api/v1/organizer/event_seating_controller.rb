# frozen_string_literal: true

module Api
  module V1
    module Organizer
      class EventSeatingController < BaseController
        before_action :set_event

        def show
          configuration = @event.event_seating_configuration
          return render json: { assigned_seating: false } unless configuration

          render json: Seating::MapPresenter.call(configuration).merge(
            assigned_seating: true,
            audit_events: @event.seat_audit_events.order(occurred_at: :desc).limit(50).map { |entry|
              {
                id: entry.id, action: entry.action, event_seat_id: entry.event_seat_id,
                actor_user_id: entry.actor_user_id, metadata: entry.metadata, occurred_at: entry.occurred_at
              }
            }
          )
        end

        def create
          layout = current_organization.venue_layouts.find(params[:venue_layout_id])
          configuration = Seating::ConfigurationActivator.call(
            event: @event,
            venue_layout: layout,
            zone_ticket_types: zone_ticket_types_param,
            actor: current_user
          )
          render json: Seating::MapPresenter.call(configuration), status: :created
        rescue Seating::ConfigurationActivator::ConfigurationError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Venue layout not found" }, status: :not_found
        end

        def suspend
          reason = params[:reason].to_s.strip
          return render json: { error: "A suspension reason is required" }, status: :unprocessable_entity if reason.blank?

          @event.with_lock { @event.update!(sales_suspended_at: Time.current, sales_suspension_reason: reason) }
          Seating::Audit.record!(event: @event, action: "seating.sales_suspended", actor: current_user,
            metadata: { reason: reason })
          render json: { suspended: true, reason: reason }
        end

        def resume
          @event.with_lock { @event.update!(sales_suspended_at: nil, sales_suspension_reason: nil) }
          Seating::Audit.record!(event: @event, action: "seating.sales_resumed", actor: current_user)
          render json: { suspended: false }
        end

        def release_accessible
          configuration = active_configuration!
          seats = configured_seats!(configuration)
          releases = Seating::AccessibleRelease.call(
            event: @event,
            event_seats: seats,
            actor: current_user,
            reason: params[:reason]
          )
          render json: { released_event_seat_ids: releases.map(&:event_seat_id) }
        rescue Seating::AccessibleRelease::ReleaseError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update_seat_statuses
          configuration = active_configuration!
          status = params[:operational_status].to_s
          unless EventSeat.operational_statuses.key?(status)
            return render json: { error: "operational_status must be available, blocked, or house_hold" },
              status: :unprocessable_entity
          end
          reason = params[:reason].to_s.strip
          return render json: { error: "A status reason is required" }, status: :unprocessable_entity if reason.blank?

          seats = configured_seats!(configuration).order(:id).lock
          updated = []
          EventSeat.transaction do
            seats.each do |seat|
              if status != "available" && !seat.selectable?
                raise Seating::HoldAllocator::HoldError, "Sold or held seats cannot be blocked"
              end
              seat.update!(operational_status: status, status_reason: reason)
              Seating::Audit.record!(event: @event, action: "seat.status_changed", event_seat: seat,
                actor: current_user, metadata: { operational_status: status, reason: reason })
              updated << seat.id
            end
          end
          render json: { updated_event_seat_ids: updated, operational_status: status }
        rescue Seating::HoldAllocator::HoldError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_event
          @event = find_organization_event(params[:event_id])
          authorize_organization!(:manage_inventory, event: @event) if @event
        end

        def active_configuration!
          configuration = @event.event_seating_configuration
          raise ActiveRecord::RecordNotFound unless configuration&.status_active?

          configuration
        end

        def configured_seats!(configuration)
          ids = Array(params[:event_seat_ids]).map(&:to_i).uniq
          seats = configuration.event_seats.where(id: ids)
          raise ActiveRecord::RecordNotFound if ids.empty? || seats.count != ids.length

          seats
        end

        def zone_ticket_types_param
          params.require(:zone_ticket_types).each_pair.to_h do |zone_id, ticket_type_id|
            [Integer(zone_id.to_s, 10), Integer(ticket_type_id.to_s, 10)]
          rescue ArgumentError
            raise ActionController::BadRequest, "Zone and ticket type IDs must be integers"
          end
        end
      end
    end
  end
end
