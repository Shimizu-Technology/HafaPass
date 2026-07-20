# frozen_string_literal: true

class FeeComponent < ApplicationRecord
  include AppendOnlyRecord

  KINDS = %w[platform processing tax organizer].freeze

  belongs_to :order
  belongs_to :order_item, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, presence: true, length: { is: 3 }
end
