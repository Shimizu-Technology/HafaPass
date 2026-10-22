module Api
  module V1
    module Organizer
      class WaitlistController < BaseController
        include Paginatable

        before_action :set_event
        before_action :set_entry, only: [:notify, :retry_unconfirmed, :offer, :destroy]

        # GET /api/v1/organizer/events/:event_id/waitlist
        def index
          entries = @event.waitlist_entries.includes(:ticket_type).order(:position)

          # Filter by status
          if params[:status].present?
            entries = entries.where(status: params[:status])
          end

          pagy, paginated_entries = paginate(entries)

          # Stats
          stats = {
            total_waiting: @event.waitlist_entries.waiting.count,
            total_notified: @event.waitlist_entries.notified.count,
            total_converted: @event.waitlist_entries.converted.count,
            total_expired: @event.waitlist_entries.expired.count,
            total_cancelled: @event.waitlist_entries.cancelled.count
          }

          render json: {
            waitlist: paginated_entries.map { |e| entry_json(e) },
            stats: stats,
            marketing_address_ready: WaitlistDelivery.address_ready?(@event),
            marketing_address_error: WaitlistDelivery::ADDRESS_ERROR,
            meta: pagination_meta(pagy)
          }
        end

        # POST /api/v1/organizer/events/:event_id/waitlist/:id/notify
        def notify
          return address_error unless WaitlistDelivery.address_ready?(@event)
          unless @entry.waiting?
            render json: { error: "Can only notify entries with 'waiting' status" }, status: :unprocessable_entity
            return
          end

          unless @entry.notify_and_queue!
            return render json: { error: "Can only notify entries with 'waiting' status" }, status: :unprocessable_entity
          end

          render json: entry_json(@entry)
        rescue WaitlistDelivery::AddressMissing
          address_error
        end

        def retry_unconfirmed
          return address_error unless WaitlistDelivery.address_ready?(@event)
          retried = if @entry.offered?
            WaitlistDelivery.retry_unconfirmed_offer!(@entry)
          else
            @entry.retry_unconfirmed_notification!
          end
          unless retried
            return render json: { error: "This alert is no longer unconfirmed; refresh the waitlist" }, status: :unprocessable_entity
          end

          render json: entry_json(@entry)
        rescue WaitlistDelivery::AddressMissing
          address_error
        end

        def offer
          offer = WaitlistOffers::Issuer.call(entry: @entry)
          render json: entry_json(@entry.reload).merge(offer: offer_json(offer)), status: :created
        rescue WaitlistOffers::Issuer::OfferError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/organizer/events/:event_id/waitlist/notify_next
        def notify_next
          return address_error unless WaitlistDelivery.address_ready?(@event)
          count = (params[:count] || 1).to_i
          count = [count, 50].min # Cap at 50

          entries = @event.waitlist_entries
            .waiting
            .order(:position)
            .limit(count)

          notified = []
          entries.each do |entry|
            notified << entry_json(entry) if entry.notify_and_queue!
          end

          render json: { notified: notified, count: notified.size }
        rescue WaitlistDelivery::AddressMissing
          address_error
        end

        # DELETE /api/v1/organizer/events/:event_id/waitlist/:id
        def destroy
          @entry.with_lock do
            @entry.waitlist_offers.where(status: [:offered, :claimed]).find_each do |offer|
              offer.update!(status: :cancelled, token_version: offer.token_version + 1)
            end
            @entry.update!(status: :cancelled, management_version: @entry.management_version + 1, expires_at: nil)
          end
          head :no_content
        end

        private

        def address_error
          render json: { error: WaitlistDelivery::ADDRESS_ERROR, settings_url: "/dashboard/settings" }, status: :unprocessable_entity
        end

        def set_event
          return if performed?
          @event = find_organization_event(params[:event_id])
          authorize_organization!(:manage_attendees, event: @event) if @event
        end

        def set_entry
          @entry = @event.waitlist_entries.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Waitlist entry not found" }, status: :not_found
        end

        def entry_json(entry)
          json = {
            id: entry.id,
            event_id: entry.event_id,
            ticket_type_id: entry.ticket_type_id,
            email: entry.email,
            name: entry.name,
            phone: entry.phone,
            quantity: entry.quantity,
            position: entry.position,
            status: entry.status,
            notified_at: entry.notified_at,
            expires_at: entry.expires_at,
            created_at: entry.created_at,
            delivery_failure: entry.delivery_failure
          }
          if entry.ticket_type
            json[:ticket_type] = { id: entry.ticket_type.id, name: entry.ticket_type.name }
          end
          json
        end


        def offer_json(offer)
          {
            id: offer.id,
            ticket_type_id: offer.ticket_type_id,
            quantity: offer.quantity,
            unit_price_cents: offer.unit_price_cents,
            status: offer.status,
            expires_at: offer.expires_at
          }
        end
      end
    end
  end
end
