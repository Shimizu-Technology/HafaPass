# frozen_string_literal: true

# Bumps PublicEventCache after commit when a record change can move public
# availability. The condition runs in the after_commit callback, where
# saved_changes still describes the committed save.
module PublicEventCacheBuster
  extend ActiveSupport::Concern

  class_methods do
    def busts_public_event_cache(on: %i[create update destroy], condition: nil)
      after_commit(on: on) do
        PublicEventCache.bump! if condition.nil? || instance_exec(&condition)
      end
    end
  end
end
