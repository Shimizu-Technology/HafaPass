# frozen_string_literal: true

class SettlementItem < ApplicationRecord
  KINDS = %w[sale_proceeds platform_fee processing_fee refund reserve adjustment dispute payout].freeze

  belongs_to :settlement

  validates :kind, inclusion: { in: KINDS }
  validates :amount_cents, numericality: { only_integer: true }
  validates :currency, length: { is: 3 }
  validates :description, :occurred_at, presence: true

  attr_readonly :settlement_id, :kind, :amount_cents, :currency, :source_type, :source_id,
    :description, :metadata, :occurred_at
end
