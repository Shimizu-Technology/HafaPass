# frozen_string_literal: true

module AppendOnlyRecord
  extend ActiveSupport::Concern

  included do
    before_update :prevent_mutation
    before_destroy :prevent_mutation
  end

  private

  def prevent_mutation
    errors.add(:base, "Financial ledger records are append-only")
    throw(:abort)
  end
end
