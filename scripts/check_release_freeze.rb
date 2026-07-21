#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

module HafaPass
  module ReleaseFreeze
    REQUIRED_LABEL = "release-approved"

    class Error < StandardError; end

    module_function

    def verify!(freeze_id:, event_name:, event_path:)
      return "Release freeze is inactive." if freeze_id.to_s.strip.empty?
      return "Release freeze #{freeze_id} is active; non-PR CI is allowed." unless event_name == "pull_request"

      raise Error, "GITHUB_EVENT_PATH is required for pull-request freeze enforcement." if event_path.to_s.empty?

      event = JSON.parse(File.read(event_path))
      labels = Array(event.dig("pull_request", "labels")).filter_map { |label| label["name"] }
      number = event.dig("pull_request", "number") || event["number"] || "unknown"

      unless labels.include?(REQUIRED_LABEL)
        raise Error,
          "Release freeze #{freeze_id} blocks PR ##{number}. A repository maintainer must add the " \
          "#{REQUIRED_LABEL.inspect} label after confirming the change belongs in the frozen candidate."
      end

      "Release freeze #{freeze_id} authorizes PR ##{number} through #{REQUIRED_LABEL.inspect}."
    rescue JSON::ParserError => e
      raise Error, "Could not parse GITHUB_EVENT_PATH: #{e.message}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts HafaPass::ReleaseFreeze.verify!(
      freeze_id: ENV["RELEASE_FREEZE"],
      event_name: ENV["GITHUB_EVENT_NAME"],
      event_path: ENV["GITHUB_EVENT_PATH"]
    )
  rescue HafaPass::ReleaseFreeze::Error => e
    warn e.message
    exit 1
  end
end
