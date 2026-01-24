module Api
  module V1
    module Organizer
      class EventsController < ApplicationController
        before_action :require_organizer_profile
        before_action :set_event, only: [:show, :update, :destroy, :publish]

        def index
          events = current_organizer_profile.events.order(created_at: :desc)
          render json: events.map { |event| event_json(event) }
        end

        def show
          render json: event_json(@event, include_ticket_types: true)
        end

        def create
          event = current_organizer_profile.events.build(event_params)
          if event.save
            render json: event_json(event), status: :created
          else
            render json: { errors: event.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          if @event.update(event_params)
            render json: event_json(@event)
          else
            render json: { errors: @event.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          @event.destroy
          head :no_content
        end

        def publish
          if @event.draft?
            @event.update!(status: :published, published_at: Time.current)
            render json: event_json(@event)
          else
            render json: { error: "Only draft events can be published" }, status: :unprocessable_entity
          end
        end

        private

        def require_organizer_profile
          unless current_organizer_profile
            render json: { error: "Organizer profile required" }, status: :forbidden
          end
        end

        def current_organizer_profile
          @current_organizer_profile ||= current_user.organizer_profile
        end

        def set_event
          @event = current_organizer_profile.events.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Event not found" }, status: :not_found
        end

        def event_params
          params.permit(
            :title, :description, :short_description, :cover_image_url,
            :venue_name, :venue_address, :venue_city,
            :starts_at, :ends_at, :doors_open_at, :timezone,
            :category, :age_restriction, :max_capacity, :is_featured
          )
        end

        def event_json(event, include_ticket_types: false)
          json = {
            id: event.id,
            title: event.title,
            slug: event.slug,
            description: event.description,
            short_description: event.short_description,
            cover_image_url: event.cover_image_url,
            venue_name: event.venue_name,
            venue_address: event.venue_address,
            venue_city: event.venue_city,
            starts_at: event.starts_at,
            ends_at: event.ends_at,
            doors_open_at: event.doors_open_at,
            timezone: event.timezone,
            status: event.status,
            category: event.category,
            age_restriction: event.age_restriction,
            max_capacity: event.max_capacity,
            is_featured: event.is_featured,
            published_at: event.published_at,
            created_at: event.created_at,
            updated_at: event.updated_at
          }

          if include_ticket_types
            json[:ticket_types] = event.ticket_types.order(:sort_order, :id).map do |tt|
              {
                id: tt.id,
                name: tt.name,
                description: tt.description,
                price_cents: tt.price_cents,
                quantity_available: tt.quantity_available,
                quantity_sold: tt.quantity_sold,
                max_per_order: tt.max_per_order,
                sales_start_at: tt.sales_start_at,
                sales_end_at: tt.sales_end_at
              }
            end
          end

          json
        end
      end
    end
  end
end
