# frozen_string_literal: true

class Api::V1::MarketplaceCollectionsController < ApplicationController
  include Paginatable
  skip_before_action :authenticate_user!

  def index
    collections = MarketplaceCollection.currently_visible.order(:position, :title).select do |collection|
      collection.discoverable_events.exists?
    end
    render json: { collections: collections.map { |collection| collection_json(collection, preview: true) } }
  end

  def show
    collection = MarketplaceCollection.currently_visible.find_by!(slug: params[:slug])
    events = collection.discoverable_events.includes(:venue, :organization, :organizer_profile, ticket_types: :pricing_tiers)
    raise ActiveRecord::RecordNotFound unless events.exists?

    pagy, records = paginate(events)
    render json: collection_json(collection).merge(
      events: records.map { |event| Marketplace::EventSerializer.call(event) },
      meta: pagination_meta(pagy)
    )
  end

  private

  def collection_json(collection, preview: false)
    json = collection.as_json(only: [:id, :title, :slug, :description, :seo_title, :seo_description])
    if preview
      json["events"] = collection.discoverable_events.limit(6).includes(:venue, :organization, :organizer_profile,
        ticket_types: :pricing_tiers).map { |event| Marketplace::EventSerializer.call(event) }
    end
    json
  end
end
