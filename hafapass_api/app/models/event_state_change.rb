# frozen_string_literal: true

class EventStateChange < ApplicationRecord
  belongs_to :event
  belongs_to :actor_user, class_name: "User"

  validates :action, :from_status, :to_status, :occurred_at, presence: true

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def prevent_mutation
    errors.add(:base, "Event state history is append-only")
    throw :abort
  end
end
