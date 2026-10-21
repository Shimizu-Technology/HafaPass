# frozen_string_literal: true

class OrganizerSalesExportRequest < ApplicationRecord
  belongs_to :event
  belongs_to :actor_user, class_name: "User"

  validates :status, inclusion: { in: %w[pending processing ready failed expired] }
end
