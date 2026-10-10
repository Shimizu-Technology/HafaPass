# frozen_string_literal: true

class ApplicationRevision
  def self.current
    # Render supplies the commit actually built/deployed. Never let a stale
    # manually configured SHA override it or mask an invalid platform value.
    render_commit = ENV["RENDER_GIT_COMMIT"]
    value = render_commit.nil? || render_commit.empty? ? ENV["GIT_SHA"].presence || ENV["COMMIT_REF"].presence : render_commit
    return value unless value.nil?
    return "development" unless Rails.env.production?

    nil
  end

  def self.configured?
    current.to_s.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i)
  end
end
