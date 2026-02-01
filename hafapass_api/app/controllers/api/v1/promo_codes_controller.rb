module Api
  module V1
    class PromoCodesController < ApplicationController
      skip_before_action :authenticate_user!

      # POST /api/v1/promo_codes/validate
      # Public endpoint for checkout to validate a promo code
      def validate
        event = Event.published.find_by(id: params[:event_id])
        unless event
          render json: { error: "Event not found" }, status: :not_found
          return
        end

        code_str = params[:code]&.strip&.upcase
        if code_str.blank?
          render json: { error: "Code is required" }, status: :unprocessable_entity
          return
        end

        promo = event.promo_codes.find_by(code: code_str)
        unless promo
          render json: { valid: false, error: "Invalid promo code" }, status: :ok
          return
        end

        unless promo.usable?
          reason = if !promo.active?
            "This promo code is no longer active"
          elsif promo.expires_at && promo.expires_at <= Time.current
            "This promo code has expired"
          elsif promo.max_uses && promo.current_uses >= promo.max_uses
            "This promo code has reached its usage limit"
          else
            "This promo code is not currently valid"
          end
          render json: { valid: false, error: reason }, status: :ok
          return
        end

        # Calculate discount for preview
        subtotal_cents = params[:subtotal_cents].to_i
        discount = promo.calculate_discount(subtotal_cents)

        render json: {
          valid: true,
          promo_code_id: promo.id,
          code: promo.code,
          discount_type: promo.discount_type,
          discount_value: promo.discount_value,
          discount_cents: discount,
          description: promo.percentage? ? "#{promo.discount_value}% off" : "$#{format('%.2f', promo.discount_value / 100.0)} off"
        }
      end
    end
  end
end
