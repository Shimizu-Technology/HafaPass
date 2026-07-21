# frozen_string_literal: true

class Api::V1::Admin::MarketplaceCollectionsController < Api::V1::Admin::BaseController
  def index
    render json: { collections: MarketplaceCollection.includes(:events).order(:position, :title).map { |item| serialize(item) } }
  end

  def create
    collection = MarketplaceCollection.new(collection_params.except(:event_ids).merge(created_by_user: current_user))
    save_with_events(collection, :created)
  end

  def update
    collection = MarketplaceCollection.find(params[:id])
    collection.assign_attributes(collection_params.except(:event_ids))
    save_with_events(collection)
  end

  def destroy
    MarketplaceCollection.find(params[:id]).destroy!
    head :no_content
  end

  private

  def save_with_events(collection, status = :ok)
    MarketplaceCollection.transaction do
      collection.save!
      if collection_params.key?(:event_ids)
        ids = Array(collection_params[:event_ids]).map(&:to_i).uniq
        unless Event.where(id: ids).count == ids.length
          collection.errors.add(:events, "contain an unknown event")
          raise ActiveRecord::RecordInvalid, collection
        end
        collection.marketplace_collection_events.destroy_all
        ids.each_with_index do |event_id, position|
          collection.marketplace_collection_events.create!(event_id: event_id, position: position)
        end
      end
    end
    render json: serialize(collection.reload), status: status
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def collection_params
    params.permit(:title, :slug, :description, :status, :position, :starts_at, :ends_at, :seo_title,
      :seo_description, event_ids: [])
  end

  def serialize(collection)
    collection.as_json(only: [:id, :title, :slug, :description, :status, :position, :starts_at, :ends_at,
      :seo_title, :seo_description]).merge(
        event_ids: collection.marketplace_collection_events.order(:position).pluck(:event_id),
        visible_event_count: collection.discoverable_events.count
      )
  end
end
