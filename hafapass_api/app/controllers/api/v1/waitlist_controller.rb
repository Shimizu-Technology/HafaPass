module Api
  module V1
    class WaitlistController < ApplicationController
      skip_before_action :authenticate_user!

      before_action :set_event

      # POST /api/v1/events/:slug/waitlist
      def create
        entry = @event.waitlist_entries.build(waitlist_params)
        entry.quantity ||= 1

        # Attach user if authenticated
        if request.headers["Authorization"].present?
          begin
            token = request.headers["Authorization"].split(" ").last
            payload = ClerkAuthenticator.verify(token)
            if payload
              user = User.find_by(clerk_id: payload["sub"])
              entry.user = user if user
            end
          rescue StandardError
            # Ignore auth errors for this optional attachment
          end
        end

        if entry.save
          render json: entry_json(entry), status: :created
        else
          render json: { errors: entry.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/events/:slug/waitlist/status
      def status
        email = params[:email]
        unless email.present?
          render json: { error: "Email is required" }, status: :bad_request
          return
        end

        entries = @event.waitlist_entries.where(email: email).order(:position)
        if entries.any?
          render json: { entries: entries.map { |e| public_entry_json(e) } }
        else
          render json: { entries: [], message: "No waitlist entries found for this email" }
        end
      end

      # DELETE /api/v1/events/:slug/waitlist
      def destroy
        email = params[:email]
        unless email.present?
          render json: { error: "Email is required" }, status: :bad_request
          return
        end

        entries = @event.waitlist_entries.where(email: email, status: [:waiting, :notified, :offered])
        if entries.any?
          entries.update_all(status: :cancelled)
          head :no_content
        else
          render json: { error: "No active waitlist entries found" }, status: :not_found
        end
      end

      private

      def set_event
        @event = Event.published.find_by!(slug: params[:slug])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      def waitlist_params
        params.permit(:email, :name, :phone, :ticket_type_id, :quantity)
      end

      def entry_json(entry)
        {
          id: entry.id,
          event_id: entry.event_id,
          ticket_type_id: entry.ticket_type_id,
          email: entry.email,
          name: entry.name,
          quantity: entry.quantity,
          position: entry.position,
          status: entry.status,
          notified_at: entry.notified_at,
          expires_at: entry.expires_at,
          created_at: entry.created_at
        }
      end

      # Limited response for unauthenticated status checks — no personal data exposed
      def public_entry_json(entry)
        {
          position: entry.position,
          status: entry.status,
          quantity: entry.quantity,
          ticket_type_id: entry.ticket_type_id,
          created_at: entry.created_at
        }
      end
    end
  end
end
