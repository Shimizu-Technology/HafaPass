# frozen_string_literal: true

# Queues one PublicEventCache bump for the enclosing transaction when a record
# change can move public availability. The condition runs right after the
# save, where saved_changes describes that save; the bump itself runs after
# the outermost commit and is coalesced to one per transaction
# (PublicEventCache.bump_after_commit!).
module PublicEventCacheBuster
  extend ActiveSupport::Concern

  CALLBACKS = { create: :after_create, update: :after_update, destroy: :after_destroy }.freeze

  class_methods do
    def busts_public_event_cache(on: %i[create update destroy], condition: nil)
      Array(on).each do |action|
        public_send(CALLBACKS.fetch(action)) do
          PublicEventCache.bump_after_commit! if condition.nil? || instance_exec(&condition)
        end
      end
    end
  end
end
