# frozen_string_literal: true

class ApplicationRevision
  def self.current
    value = ENV["GIT_SHA"].presence || ENV["COMMIT_REF"].presence
    return value if value.present?
    return "development" unless Rails.env.production?

    nil
  end

  def self.configured?
    current.to_s.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i)
  end
end
