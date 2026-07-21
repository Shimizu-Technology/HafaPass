# frozen_string_literal: true

module Api
  module V1
    module Organizer
      class VenueLayoutsController < BaseController
        before_action :authorize_layout_management

        def index
          layouts = current_organization.venue_layouts.includes(:venue, :venue_seats).order(created_at: :desc)
          render json: { venue_layouts: layouts.map { |layout| summary_json(layout) } }
        end

        def show
          render json: layout_json(find_layout)
        end

        def create
          layout = nil
          VenueLayout.transaction do
            venue = Venue.published.find(params[:venue_id])
            layout = current_organization.venue_layouts.create!(
              venue: venue,
              name: params[:name],
              version: params[:version].presence || 1,
              renderer: params[:renderer].presence || :internal,
              provider_chart_key: params[:provider_chart_key]
            )
            create_zones!(layout)
            create_sections!(layout)
            layout.update!(status: :published) if ActiveModel::Type::Boolean.new.cast(params[:publish])
          end
          render json: layout_json(layout), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Venue not found" }, status: :not_found
        end

        def update
          layout = find_layout
          layout.update!(params.permit(:name, :status, :provider_chart_key))
          render json: layout_json(layout)
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def authorize_layout_management
          authorize_organization!(:manage_inventory)
        end

        def find_layout
          current_organization.venue_layouts.find(params[:id])
        end

        def create_zones!(layout)
          zones = Array(params[:price_zones])
          if zones.empty?
            layout.errors.add(:base, "At least one price zone is required")
            raise ActiveRecord::RecordInvalid.new(layout)
          end

          zones.each_with_index do |zone, index|
            layout.seating_price_zones.create!(
              name: zone[:name], code: zone[:code], color: zone[:color].presence || "#2563EB", position: index
            )
          end
        end

        def create_sections!(layout)
          zones = layout.seating_price_zones.index_by(&:code)
          Array(params[:sections]).each_with_index do |section_params, section_index|
            section = layout.seating_sections.create!(
              name: section_params[:name], code: section_params[:code], position: section_index
            )
            Array(section_params[:rows]).each_with_index do |row_params, row_index|
              row = section.seating_rows.create!(label: row_params[:label], position: row_index)
              Array(row_params[:seats]).each_with_index do |seat_params, seat_index|
                row.venue_seats.create!(
                  seating_price_zone: zones.fetch(seat_params[:price_zone_code].to_s),
                  label: seat_params[:label],
                  position: seat_params[:position].presence || seat_index,
                  x: seat_params[:x], y: seat_params[:y],
                  accessibility_kind: seat_params[:accessibility_kind].presence || :standard,
                  companion_group: seat_params[:companion_group],
                  obstructed_view: seat_params[:obstructed_view] || false,
                  view_note: seat_params[:view_note]
                )
              end
            end
          end
        rescue KeyError
          layout.errors.add(:base, "Every seat must reference a known price_zone_code")
          raise ActiveRecord::RecordInvalid.new(layout)
        end

        def summary_json(layout)
          {
            id: layout.id,
            name: layout.name,
            version: layout.version,
            status: layout.status,
            renderer: layout.renderer,
            seat_count: layout.venue_seats.length,
            venue: { id: layout.venue_id, name: layout.venue.name }
          }
        end

        def layout_json(layout)
          summary_json(layout).merge(
            price_zones: layout.seating_price_zones.map { |zone|
              { id: zone.id, name: zone.name, code: zone.code, color: zone.color }
            },
            sections: layout.seating_sections.includes(seating_rows: { venue_seats: :seating_price_zone }).map { |section|
              {
                id: section.id,
                name: section.name,
                code: section.code,
                rows: section.seating_rows.map { |row|
                  {
                    id: row.id,
                    label: row.label,
                    seats: row.venue_seats.map { |seat|
                      {
                        id: seat.id,
                        label: seat.label,
                        position: seat.position,
                        price_zone_code: seat.seating_price_zone.code,
                        accessibility_kind: seat.accessibility_kind,
                        companion_group: seat.companion_group,
                        obstructed_view: seat.obstructed_view,
                        view_note: seat.view_note
                      }
                    }
                  }
                }
              }
            }
          )
        end
      end
    end
  end
end
