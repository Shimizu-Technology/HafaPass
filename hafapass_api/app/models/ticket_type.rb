class TicketType < ApplicationRecord
  belongs_to :event

  validates :name, presence: true
  validates :price_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity_available, presence: true, numericality: { greater_than: 0 }

  def sold_out?
    quantity_sold >= quantity_available
  end

  def available_quantity
    quantity_available - quantity_sold
  end
end
