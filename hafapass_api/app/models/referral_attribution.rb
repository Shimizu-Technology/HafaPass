# frozen_string_literal: true

class ReferralAttribution < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :order
  belongs_to :promoter

  validates :code_snapshot, :attributed_at, presence: true
  validates :order_id, uniqueness: true
end
