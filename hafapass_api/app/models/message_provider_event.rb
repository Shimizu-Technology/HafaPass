# frozen_string_literal: true

class MessageProviderEvent < ApplicationRecord
  belongs_to :message_delivery, optional: true

  validates :provider, :provider_event_id, :event_type, :occurred_at, :received_at, presence: true
  validates :provider_event_id, uniqueness: { scope: :provider }

  attr_readonly :provider, :provider_event_id, :provider_message_id, :event_type, :occurred_at, :received_at, :payload
end
