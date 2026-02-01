module Api
  module V1
    module Organizer
      class PromoCodesController < ApplicationController
        before_action :require_organizer_profile
        before_action :set_event
        before_action :set_promo_code, only: [:show, :update, :destroy]

        # GET /api/v1/organizer/events/:event_id/promo_codes
        def index
          promo_codes = @event.promo_codes.order(created_at: :desc)
          render json: promo_codes.map { |pc| promo_code_json(pc) }
        end

        # GET /api/v1/organizer/events/:event_id/promo_codes/:id
        def show
          render json: promo_code_json(@promo_code)
        end

        # POST /api/v1/organizer/events/:event_id/promo_codes
        def create
          promo_code = @event.promo_codes.build(promo_code_params)
          if promo_code.save
            render json: promo_code_json(promo_code), status: :created
          else
            render json: { errors: promo_code.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/v1/organizer/events/:event_id/promo_codes/:id
        def update
          if @promo_code.update(promo_code_params)
            render json: promo_code_json(@promo_code)
          else
            render json: { errors: @promo_code.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/organizer/events/:event_id/promo_codes/:id
        def destroy
          @promo_code.destroy
          head :no_content
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
          @event = current_organizer_profile.events.find(params[:event_id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Event not found" }, status: :not_found
        end

        def set_promo_code
          @promo_code = @event.promo_codes.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Promo code not found" }, status: :not_found
        end

        def promo_code_params
          params.permit(:code, :discount_type, :discount_value, :max_uses, :starts_at, :expires_at, :active)
        end

        def promo_code_json(pc)
          {
            id: pc.id,
            code: pc.code,
            discount_type: pc.discount_type,
            discount_value: pc.discount_value,
            max_uses: pc.max_uses,
            current_uses: pc.current_uses,
            starts_at: pc.starts_at,
            expires_at: pc.expires_at,
            active: pc.active,
            usable: pc.usable?,
            created_at: pc.created_at
          }
        end
      end
    end
  end
end
