# frozen_string_literal: true

class RegistrationResponse < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :order
  belongs_to :registration_question

  validates :prompt_snapshot, :kind_snapshot, :answered_at, presence: true
  validates :registration_question_id, uniqueness: { scope: :order_id }
  validates :required_snapshot, inclusion: { in: [true, false] }
  validates :options_snapshot, presence: true, if: -> { kind_snapshot == RegistrationQuestion.kinds.fetch("selection") }
end
