# frozen_string_literal: true

module Api
  module V1
    module Organizer
      class EventSeriesController < BaseController
        REVENUE_SHARE_FIELDS = %w[
          revenue_share_bps
          revenue_share_base
          revenue_share_includes_door_cash
          revenue_share_label
          primary_share_label
        ].freeze

        before_action :authorize_org_wide_event_viewer!, only: [:index, :show]
        before_action :authorize_finance_viewer!, only: [:report, :report_export]
        before_action :authorize_update_action!, only: [:update]
        before_action :authorize_manage_events!, only: [:create, :destroy, :add_event, :update_event, :remove_event]
        before_action :set_event_series, only: [:show, :update, :destroy, :add_event, :update_event, :remove_event, :report, :report_export]

        def index
          series = current_organization.event_series
            .includes(event_series_memberships: :event)
            .order(created_at: :desc, id: :desc)

          render json: {
            event_series: series.map { |item| series_json(item, include_events: true) }
          }
        end

        def show
          render json: series_json(@event_series, include_events: true)
        end

        def create
          series = current_organization.event_series.build(series_params)
          if series.save
            render json: series_json(series, include_events: true), status: :created
          else
            render json: { errors: series.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { errors: ["Slug has already been taken"] }, status: :unprocessable_entity
        end

        def update
          if @event_series.update(@permitted_series_params)
            render json: series_json(@event_series.reload, include_events: true)
          else
            render json: { errors: @event_series.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { errors: ["Slug has already been taken"] }, status: :unprocessable_entity
        end

        def report
          render json: EventSeriesReport.call(@event_series)
        end

        def report_export
          report_data = EventSeriesReport.call(@event_series)
          AuditLogger.record!(
            action: "finance.exported",
            auditable: @event_series,
            actor: current_user,
            organization: current_organization,
            metadata: { export: "event_series_report", scope: "event_series", format: "csv" },
            request: request
          )
          response.headers["Cache-Control"] = "no-store, no-cache"
          send_data(
            EventSeriesReportExport.to_csv(report_data),
            filename: EventSeriesReportExport.safe_filename(@event_series),
            type: "text/csv; charset=utf-8",
            disposition: "attachment"
          )
        end

        def destroy
          if @event_series.event_series_memberships.exists?
            return render json: { error: "Remove all events from this series or archive it before deleting" },
              status: :unprocessable_entity
          end

          @event_series.destroy!
          head :no_content
        end

        def add_event
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
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "Event is already in this series" }, status: :unprocessable_entity
        end

        def update_event
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
          membership = @event_series.event_series_memberships.find_by(event_id: params[:event_id])
          return render json: { error: "Event is not in this series" }, status: :not_found unless membership

          membership.destroy!
          head :no_content
        end

        private

        def authorize_finance_viewer!
          authorize_organization!(:view_finance)
        end

        def authorize_manage_events!
          authorize_organization!(:manage_events)
        end

        def authorize_update_action!
          @permitted_series_params = series_params
          authorize_series_update!(@permitted_series_params)
        end

        def authorize_series_update!(permitted)
          keys = permitted.keys.map(&:to_s)
          has_revenue_share = (keys & REVENUE_SHARE_FIELDS).any?
          has_non_revenue_share = (keys - REVENUE_SHARE_FIELDS).any?

          if has_revenue_share
            return false unless authorize_organization!(:manage_finance)
          end

          if has_non_revenue_share || !has_revenue_share
            return false unless authorize_organization!(:manage_events)
          end

          true
        end

        def authorize_org_wide_event_viewer!
          return true if OrganizationAuthorization.org_wide_event_viewer?(
            user: current_user,
            organization: current_organization
          )

          render json: { error: "You do not have permission to perform this action" }, status: :forbidden
          false
        end

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
