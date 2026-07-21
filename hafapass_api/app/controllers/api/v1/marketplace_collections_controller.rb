# frozen_string_literal: true

class Api::V1::MarketplaceCollectionsController < ApplicationController
  include Paginatable
  skip_before_action :authenticate_user!

  def index
    collections = MarketplaceCollection.currently_visible.with_discoverable_events.order(:position, :title).to_a
    previews = preview_events_by_collection(collections)
    render json: {
      collections: collections.map { |collection|
        collection_json(collection, preview_events: previews.fetch(collection.id, []))
      }
    }
  end

  def show
    collection = MarketplaceCollection.currently_visible.find_by!(slug: params[:slug])
    events = collection.discoverable_events.includes(:venue, :organization, :organizer_profile,
      ticket_types: [:inventory_holds, :waitlist_offers,
        { pricing_tiers: [:inventory_holds, :waitlist_offers] }])
    raise ActiveRecord::RecordNotFound unless events.exists?

    pagy, records = paginate(events)
    render json: collection_json(collection).merge(
      events: records.map { |event| Marketplace::EventSerializer.call(event, purchasable: true) },
      meta: pagination_meta(pagy)
    )
  end

  private

  def collection_json(collection, preview_events: nil)
    json = collection.as_json(only: [:id, :title, :slug, :description, :seo_title, :seo_description])
    json["events"] = preview_events if preview_events
    json
  end

  def preview_events_by_collection(collections)
    return {} if collections.empty?

    ranked = MarketplaceCollectionEvent.joins(:event).merge(Event.discoverable)
      .where(marketplace_collection_id: collections.map(&:id))
      .select("marketplace_collection_events.*",
        "ROW_NUMBER() OVER (PARTITION BY marketplace_collection_events.marketplace_collection_id " \
        "ORDER BY marketplace_collection_events.position, marketplace_collection_events.id) AS preview_rank")
    memberships = MarketplaceCollectionEvent.from("(#{ranked.to_sql}) marketplace_collection_events")
      .where("preview_rank <= 6")
      .includes(event: [:venue, :organization, :organizer_profile,
        { ticket_types: [:inventory_holds, :waitlist_offers,
          { pricing_tiers: [:inventory_holds, :waitlist_offers] }] }])
      .order(:marketplace_collection_id, :position, :id)
    memberships.group_by(&:marketplace_collection_id).transform_values do |items|
      items.map { |membership| Marketplace::EventSerializer.call(membership.event, purchasable: true) }
    end
  end
end
