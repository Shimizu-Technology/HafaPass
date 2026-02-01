class Order < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :event
  belongs_to :promo_code, optional: true
  has_many :tickets, dependent: :destroy

  enum :status, { pending: 0, completed: 1, refunded: 2, cancelled: 3, partially_refunded: 4 }

  validates :buyer_email, presence: true
  validates :buyer_name, presence: true
end
