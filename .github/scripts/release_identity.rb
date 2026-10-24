#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "release_build_number"

module GitHubReleaseIdentity
  TAG_PATTERN = /\Av(?<version>[0-9]+\.[0-9]+\.[0-9]+)(?:-(?<channel>beta|rc)\.(?<sequence>[1-9][0-9]*))?\z/

  class Error < StandardError; end

  module_function

  def parse(payload)
    release_id = Integer(payload.fetch("id"), exception: false)
    unless release_id&.positive?
      raise Error, "GitHub release ID must be a positive integer"
    end
    raise Error, "GitHub release must be published" if payload["draft"] == true || payload["published_at"].to_s.empty?

    tag = payload.fetch("tag_name").to_s
    match = TAG_PATTERN.match(tag)
    raise Error, "Tag must use vMAJOR.MINOR.PATCH, optionally followed by -beta.N or -rc.N" unless match

    prerelease = payload.fetch("prerelease")
    raise Error, "GitHub prerelease must be true or false" unless [true, false].include?(prerelease)

    expected_prerelease = !match[:channel].nil?
    if prerelease != expected_prerelease
      raise Error, "GitHub prerelease flag does not match tag #{tag}"
    end
    { "tag" => tag, "version" => match[:version], "prerelease" => prerelease,
      "channel" => prerelease ? "testflight" : "app-store" }
  rescue KeyError => error
    raise Error, "GitHub release payload is missing #{error.key}"
  end

  def metadata(commit, payload, command: Open3.method(:capture2e))
    identity = parse(payload)
    { "tag" => identity.fetch("tag"), "version" => identity.fetch("version"),
      "build_number" => AppleReleaseBuildNumber.for_release(commit, payload, command: command),
      "release_id" => payload.fetch("id"), "commit" => commit }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.generate(GitHubReleaseIdentity.metadata(ARGV.fetch(0), JSON.parse($stdin.read)))
  rescue GitHubReleaseIdentity::Error, AppleReleaseBuildNumber::Error, IndexError, JSON::ParserError => error
    warn "Invalid published release metadata: #{error.message}"
    exit 1
  end
end
