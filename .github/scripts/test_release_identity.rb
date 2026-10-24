#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require_relative "release_identity"

class GitHubReleaseIdentityTest < Minitest::Test
  def payload(tag = "v1.0.5", prerelease = false)
    { "id" => 390_000_001, "tag_name" => tag, "draft" => false,
      "prerelease" => prerelease, "published_at" => "2026-09-01T10:00:00Z" }
  end

  def test_stable_beta_and_candidate_share_the_shipping_marketing_version
    [payload, payload("v1.1.0-beta.3", true), payload("v1.1.0-rc.1", true)].each do |release|
      identity = GitHubReleaseIdentity.parse(release)
      assert_equal release.fetch("tag_name").split("-", 2).first.delete_prefix("v"), identity.fetch("version")
      assert_equal release.fetch("tag_name"), identity.fetch("tag")
      assert_equal release.fetch("prerelease"), identity.fetch("prerelease")
    end
  end

  def test_metadata_reuses_the_shipping_build_number_for_each_release
    command = lambda do |*args|
      assert_equal ["git", "rev-list", "--first-parent", "a" * 40], args
      ["#{'a' * 40}\n#{AppleReleaseBuildNumber::BASELINE_COMMIT}\n", Struct.new(:success?).new(true)]
    end
    [payload, payload("v1.1.0-beta.3", true).merge("id" => 390_000_002)].each do |release|
      result = GitHubReleaseIdentity.metadata("a" * 40, release, command: command)
      assert_equal release.fetch("id").to_s, result.fetch("build_number")
      assert_equal "a" * 40, result.fetch("commit")
      assert_equal release.fetch("id"), result.fetch("release_id")
    end
    legacy = payload.merge("id" => AppleReleaseBuildNumber::LAST_COMMIT_NUMBERED_RELEASE_ID)
    assert_equal "382818669", GitHubReleaseIdentity.metadata("a" * 40, legacy, command: command).fetch("build_number")
  end

  def test_invalid_or_unpublished_metadata_fails_without_inspecting_git
    [{ "tag_name" => "1.0.5" }, { "prerelease" => true }, { "prerelease" => nil },
     { "draft" => true }, { "published_at" => nil }, { "id" => 0 }].each do |change|
      assert_raises(GitHubReleaseIdentity::Error) do
        GitHubReleaseIdentity.metadata("a" * 40, payload.merge(change), command: ->(*) { flunk "must not inspect git" })
      end
    end
  end
end
