# frozen_string_literal: true

class MarketplaceCollectionEvent < ApplicationRecord
  belongs_to :marketplace_collection
  belongs_to :event
  validates :event_id, uniqueness: { scope: :marketplace_collection_id }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
