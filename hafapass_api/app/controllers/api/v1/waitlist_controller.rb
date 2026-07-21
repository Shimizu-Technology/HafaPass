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
        entry = managed_entry
        return unless entry

        render json: { entries: [public_entry_json(entry)] }
      end

      # DELETE /api/v1/events/:slug/waitlist
      def destroy
        entry = managed_entry
        return unless entry
        unless entry.active?
          return render json: { error: "No active waitlist entry found" }, status: :not_found
        end

        entry.with_lock do
          entry.waitlist_offers.where(status: [:offered, :claimed]).find_each do |offer|
            offer.update!(status: :cancelled, token_version: offer.token_version + 1)
          end
          entry.update!(status: :cancelled, management_version: entry.management_version + 1, expires_at: nil)
        end
        head :no_content
      end

      private

      def set_event
        @event = Event.published.where(live_money_proof_candidate: false).find_by!(slug: params[:slug])
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
        }.merge(management_token: entry.management_credential)
      end

      def managed_entry
        entry = WaitlistCredential.find_management(params[:management_token])
        return entry if entry&.event_id == @event.id

        render json: { error: "Waitlist entry not found" }, status: :not_found
        nil
      end

      # Limited response available only after verifying a signed entry credential.
      def public_entry_json(entry)
        {
          id: entry.id,
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
