class Order < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :event
  has_many :tickets, dependent: :destroy

  enum :status, { pending: 0, completed: 1, refunded: 2, cancelled: 3 }

  validates :buyer_email, presence: true
  validates :buyer_name, presence: true
end
