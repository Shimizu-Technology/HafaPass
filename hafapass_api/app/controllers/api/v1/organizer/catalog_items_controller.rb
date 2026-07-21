# frozen_string_literal: true

class Api::V1::Organizer::CatalogItemsController < Api::V1::Organizer::EventResourcesController
  def index
    render json: { catalog_items: event.catalog_items.order(:position, :id).map { |item| serialize(item) } }
  end

  def create
    render_record(event.catalog_items.build(record_params), status: :created)
  end

  def update
    item = event.catalog_items.find(params[:id])
    item.assign_attributes(record_params)
    render_record(item)
  end

  def destroy
    destroy_record(event.catalog_items.find(params[:id]))
  end

  private

  def resource_permission
    :manage_inventory
  end

  def record_params
    params.permit(:name, :description, :kind, :price_cents, :minimum_price_cents, :maximum_price_cents,
      :inventory_quantity, :position, :active)
  end

  def serialize(item)
    item.as_json(only: [:id, :name, :description, :kind, :price_cents, :minimum_price_cents,
      :maximum_price_cents, :inventory_quantity, :quantity_sold, :position, :active]).merge(
        quantity_remaining: item.inventory_quantity ? item.available_quantity : nil
      )
  end
end
