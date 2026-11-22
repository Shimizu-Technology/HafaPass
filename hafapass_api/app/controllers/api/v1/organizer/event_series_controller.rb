# frozen_string_literal: true

module Api
  module V1
    module Organizer
      class EventSeriesController < BaseController
        before_action :set_event_series, only: [:show, :update, :destroy, :add_event, :update_event, :remove_event]

        def index
          return unless authorize_organization!(:view_events)

          series = current_organization.event_series
            .includes(event_series_memberships: :event)
            .order(created_at: :desc, id: :desc)

          render json: {
            event_series: series.map { |item| series_json(item, include_events: true) }
          }
        end

        def show
          return unless authorize_organization!(:view_events)

          render json: series_json(@event_series, include_events: true)
        end

        def create
          return unless authorize_organization!(:manage_events)

          series = current_organization.event_series.build(series_params)
          if series.save
            render json: series_json(series, include_events: true), status: :created
          else
            render json: { errors: series.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update
          return unless authorize_organization!(:manage_events)

          if @event_series.update(series_params)
            render json: series_json(@event_series.reload, include_events: true)
          else
            render json: { errors: @event_series.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def destroy
          return unless authorize_organization!(:manage_events)

          if @event_series.event_series_memberships.exists?
            return render json: { error: "Remove all events from this series or archive it before deleting" },
              status: :unprocessable_entity
          end

          @event_series.destroy!
          head :no_content
        end

        def add_event
          return unless authorize_organization!(:manage_events)

          event = current_organization.events.find_by(id: params[:event_id])
          return render json: { error: "Event not found" }, status: :not_found unless event

          role = params[:role].presence || "regular_night"
          unless EventSeriesMembership.roles.key?(role.to_s)
            return render json: { error: "Invalid series role" }, status: :unprocessable_entity
          end

          position = if params[:position].present?
            params[:position].to_i
          else
            (@event_series.event_series_memberships.maximum(:position) || -1) + 1
          end

          membership = @event_series.event_series_memberships.build(
            event: event,
            role: role,
            position: position
          )
          if membership.save
            render json: series_json(@event_series.reload, include_events: true), status: :created
          else
            render json: { errors: membership.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update_event
          return unless authorize_organization!(:manage_events)

          membership = @event_series.event_series_memberships.find_by(event_id: params[:event_id])
          return render json: { error: "Event is not in this series" }, status: :not_found unless membership

          attrs = {}
          if params.key?(:role)
            unless EventSeriesMembership.roles.key?(params[:role].to_s)
              return render json: { error: "Invalid series role" }, status: :unprocessable_entity
            end
            attrs[:role] = params[:role]
          end
          attrs[:position] = params[:position].to_i if params.key?(:position)

          if membership.update(attrs)
            render json: series_json(@event_series.reload, include_events: true)
          else
            render json: { errors: membership.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def remove_event
          return unless authorize_organization!(:manage_events)

          membership = @event_series.event_series_memberships.find_by(event_id: params[:event_id])
          return render json: { error: "Event is not in this series" }, status: :not_found unless membership

          membership.destroy!
          head :no_content
        end

        private

        def set_event_series
          @event_series = current_organization.event_series
            .includes(event_series_memberships: :event)
            .find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Event series not found" }, status: :not_found
        end

        def series_params
          permitted = params.permit(
            :name, :slug, :description, :status,
            :revenue_share_bps, :revenue_share_base,
            :revenue_share_includes_door_cash,
            :revenue_share_label, :primary_share_label
          )
          permitted.delete(:slug) if permitted.key?(:slug) && permitted[:slug].blank? && action_name == "update"
          permitted
        end

        def series_json(series, include_events: false)
          memberships = series.event_series_memberships
          json = {
            id: series.id,
            organization_id: series.organization_id,
            name: series.name,
            slug: series.slug,
            description: series.description,
            status: series.status,
            revenue_share_bps: series.revenue_share_bps,
            revenue_share_base: series.revenue_share_base,
            revenue_share_includes_door_cash: series.revenue_share_includes_door_cash,
            revenue_share_label: series.revenue_share_label,
            primary_share_label: series.primary_share_label,
            events_count: memberships.size,
            created_at: series.created_at,
            updated_at: series.updated_at
          }

          if include_events
            json[:events] = memberships.map do |membership|
              event = membership.event
              {
                id: event.id,
                membership_id: membership.id,
                event_id: event.id,
                role: membership.role,
                position: membership.position,
                title: event.title,
                slug: event.slug,
                status: event.status,
                starts_at: event.starts_at,
                ends_at: event.ends_at,
                doors_open_at: event.doors_open_at,
                timezone: event.timezone,
                venue_name: event.venue_name
              }
            end
          end

          json
        end
      end
    end
  end
end
