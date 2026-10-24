#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "release_contract"
require_relative "test_release_upgrade_workflow"

class GitHubReleaseContractTest < Minitest::Test
  def payload(tag: "v1.2.0", prerelease: false, body: valid_body)
    {
      "id" => 241_000_123,
      "tag_name" => tag,
      "draft" => false,
      "prerelease" => prerelease,
      "published_at" => "2026-09-01T10:00:00Z",
      "body" => body
    }
  end

  def valid_body
    <<~MARKDOWN
      Notes for GitHub readers stay outside the Apple sections.

      ## English
      Faster photo loading.

      ## Contributors
      Thanks to an external contributor.
    MARKDOWN
  end

  def test_stable_release_routes_to_app_store
    release = GitHubReleaseContract.parse(payload)

    assert_equal "1.2.0", release.version
    assert_equal "app-store", release.channel
    assert_equal "Faster photo loading.", release.notes.dig("IOS", "en-US")
    assert_equal "Faster photo loading.", release.notes.dig("MAC_OS", "en-US")
    assert_equal "Faster photo loading.", release.notes.dig("IOS", "de-DE")
    refute_includes release.notes.values.flat_map(&:values).join, "contributor"
  end

  def test_beta_and_release_candidate_route_to_internal_testflight
    %w[v1.2.0-beta.1 v1.2.0-rc.3].each do |tag|
      release = GitHubReleaseContract.parse(payload(tag: tag, prerelease: true))

      assert_equal "1.2.0", release.version
      assert_equal "testflight", release.channel
    end
  end

  def test_published_shipping_metadata_matches_the_prechange_golden_values
    # Derived from 059b1001: capture the tag's numeric version; IDs above 383102208
    # become the Apple build unchanged. These IDs were checked against published releases.
    golden = [
      ["v1.1.0-beta.3", 408_645_166, "1.1.0", "408645166"],
      ["v1.1.0-beta.2", 406_396_439, "1.1.0", "406396439"],
      ["v1.0.5", 397_223_379, "1.0.5", "397223379"],
      ["v1.0.5-beta.3", 397_183_579, "1.0.5", "397183579"]
    ]
    baseline = "059b1001591cac5a31d858bace98d23482950510"
    Dir.mktmpdir do |directory|
      %w[release_contract.rb release_build_number.rb].each do |name|
        content, status = Open3.capture2("git", "show", "#{baseline}:.github/scripts/#{name}")
        assert status.success?, "The immutable prechange release code must be available"
        File.binwrite(File.join(directory, name), content)
      end
      script = <<~CODE
        require "json"
        payload = JSON.parse($stdin.read)
        version = GitHubReleaseContract.parse(payload).version
        build = AppleReleaseBuildNumber.for_release(ARGV.fetch(0), payload)
        print JSON.generate({ "version" => version, "build_number" => build })
      CODE
      golden.each do |tag, id, version, build|
        sha, status = Open3.capture2("git", "rev-parse", "#{tag}^{commit}")
        assert status.success?, "Published release tag #{tag} must be available"
        data = payload(tag: tag, prerelease: tag.include?("-")).merge("id" => id)
        expected = JSON.generate({ "version" => version, "build_number" => build }).b
        before, status = Open3.capture2("ruby", "-r", File.join(directory, "release_contract.rb"),
          "-r", File.join(directory, "release_build_number.rb"), "-e", script, sha.strip,
          stdin_data: JSON.generate(data))
        assert status.success?, "The original shipping derivation must succeed for #{tag}"
        assert_equal expected, before.b, "Prechange shipping metadata must match the golden values for #{tag}"

        release = GitHubReleaseContract.parse(data)
        shipping_build = AppleReleaseBuildNumber.for_release(sha.strip, data)
        after = JSON.generate({ "version" => release.version, "build_number" => shipping_build }).b
        assert_equal expected, after, "Shipping metadata must remain byte-identical for #{tag}"
        metadata = GitHubReleaseIdentity.metadata(sha.strip, data)
        assert_equal version, metadata.fetch("version"), "Probe version must match shipping for #{tag}"
        assert_equal build, metadata.fetch("build_number"), "Probe build must match shipping for #{tag}"
      end
    end
  end

  def test_prerelease_flag_must_match_the_tag
    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload(tag: "v1.2.0-beta.1", prerelease: false))
    end

    assert_match(/prerelease flag/, error.message)
  end

  def test_release_requires_english_apple_notes
    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload(body: "## Deutsch\nNur Deutsch."))
    end

    assert_match(/English/, error.message)
  end

  def test_release_rejects_duplicate_apple_note_sections
    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload(body: "## English\nA\n## English\nB"))
    end

    assert_match(/duplicate sections/, error.message)
  end

  def test_release_accepts_windows_line_endings_and_repeated_unrelated_sections
    body = valid_body + "\n## Fixed\nOne\n## Fixed\nTwo\n"
    release = GitHubReleaseContract.parse(payload(body: body.gsub("\n", "\r\n")))

    assert_equal "Faster photo loading.", release.notes.dig("IOS", "en-US")
  end

  def test_platform_sections_combine_shared_and_platform_specific_notes
    body = <<~MARKDOWN
      ## English
      ### All Platforms
      Improved reliability.

      ### iOS and iPadOS
      Improved swipe-to-dismiss.

      ### macOS
      Fixed window restoration.
    MARKDOWN

    release = GitHubReleaseContract.parse(payload(body: body))

    assert_equal "Improved reliability.\n\nImproved swipe-to-dismiss.", release.notes.dig("IOS", "en-US")
    assert_equal "Improved reliability.\n\nFixed window restoration.", release.notes.dig("MAC_OS", "en-US")
    assert_equal release.notes.dig("IOS", "en-US"), release.notes.dig("IOS", "de-DE")
    assert_equal release.notes.dig("MAC_OS", "en-US"), release.notes.dig("MAC_OS", "de-DE")
  end

  def test_optional_german_section_can_have_independent_platform_notes
    body = <<~MARKDOWN
      ## English
      Shared English notes.

      ## Deutsch
      ### All Platforms
      Gemeinsame deutsche Hinweise.

      ### iOS and iPadOS
      Verbesserte Gesten.

      ### macOS
      Verbesserte Fensterwiederherstellung.
    MARKDOWN

    release = GitHubReleaseContract.parse(payload(body: body))

    assert_equal "Shared English notes.", release.notes.dig("IOS", "en-US")
    assert_equal "Gemeinsame deutsche Hinweise.\n\nVerbesserte Gesten.", release.notes.dig("IOS", "de-DE")
    assert_equal(
      "Gemeinsame deutsche Hinweise.\n\nVerbesserte Fensterwiederherstellung.",
      release.notes.dig("MAC_OS", "de-DE")
    )
  end

  def test_platform_sections_require_notes_for_each_platform
    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload(body: "## English\n### iOS and iPadOS\nOnly mobile."))
    end

    assert_match(/no release notes for macOS/, error.message)
  end

  def test_platform_sections_reject_ambiguous_preamble_and_unknown_headings
    preamble_error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(
        payload(body: "## English\nShared.\n### iOS and iPadOS\nMobile.\n### macOS\nDesktop.")
      )
    end
    unknown_error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload(body: "## English\n### iOS\nMobile.\n### macOS\nDesktop."))
    end

    assert_match(/All Platforms/, preamble_error.message)
    assert_match(/unsupported platform sections: iOS/, unknown_error.message)
  end

  def test_platform_sections_reject_duplicates
    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(
        payload(body: "## English\n### All Platforms\nA\n### All Platforms\nB")
      )
    end

    assert_match(/duplicate platform sections/, error.message)
  end

  def test_platform_sections_enforce_the_apple_limit_after_composition
    body = <<~MARKDOWN
      ## English
      ### All Platforms
      #{"a" * 3_000}

      ### iOS and iPadOS
      #{"b" * 1_001}

      ### macOS
      Short desktop note.
    MARKDOWN

    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload(body: body))
    end

    assert_match(/English for iOS and iPadOS exceeds 4000 characters/, error.message)
  end

  def test_release_rejects_draft_or_unpublished_payload
    error = assert_raises(GitHubReleaseContract::Error) do
      GitHubReleaseContract.parse(payload.merge("draft" => true))
    end

    assert_match(/must be published/, error.message)
  end

  def test_write_creates_only_localized_apple_notes
    Dir.mktmpdir do |directory|
      output = File.join(directory, "output")
      notes = File.join(directory, "notes")
      release = GitHubReleaseContract.parse(payload)

      GitHubReleaseContract.write(release, directory: notes, output_path: output, summary_path: nil)

      assert_equal "Faster photo loading.\n", File.read(File.join(notes, "ios.de-DE.txt"))
      assert_equal "Faster photo loading.\n", File.read(File.join(notes, "ios.en-US.txt"))
      assert_equal "Faster photo loading.\n", File.read(File.join(notes, "macos.de-DE.txt"))
      assert_equal "Faster photo loading.\n", File.read(File.join(notes, "macos.en-US.txt"))
      output_values = File.readlines(output, chomp: true).to_h { |line| line.split("=", 2) }
      assert_equal "app-store", output_values.fetch("channel")
      refute output_values.key?("build_number")
      assert_equal(
        "Faster photo loading.",
        Base64.strict_decode64(output_values.fetch("notes_ios_de_base64"))
      )
      assert_equal(
        "Faster photo loading.",
        Base64.strict_decode64(output_values.fetch("notes_macos_en_base64"))
      )
    end
  end

  def test_external_testflight_workflow_promotes_a_published_release_without_uploading
    workflow_path = File.expand_path("../workflows/testflight-external.yml", __dir__)
    workflow = File.read(workflow_path, encoding: "UTF-8")

    assert_match(/^  workflow_dispatch:$/m, workflow)
    refute_match(/^  release:$/m, workflow)
    assert_includes workflow, "group: apple-distribution"
    assert_includes workflow, '[[ "$GITHUB_REF" == "refs/heads/main" ]]'
    assert_includes workflow, "ref: main"
    assert_includes workflow, "fetch-depth: 0"
    assert_includes workflow, "git merge-base --is-ancestor"
    assert_includes workflow, "release_contract.rb"
    assert_includes workflow, "release_build_number.rb"
    assert_includes workflow, "steps.build.outputs.build_number"
    refute_includes workflow, "steps.release.outputs.build_number"
    assert_includes workflow, "wait-builds"
    assert_includes workflow, "distribute-external"
    assert_includes workflow, "IOS:en-US="
    assert_includes workflow, "MAC_OS:en-US="
    refute_match(/xcodebuild|altool|upload-artifact/, workflow)
  end

  def test_apple_release_workflow_uses_trusted_automation_for_secret_bearing_jobs
    workflow_path = File.expand_path("../workflows/testflight-internal.yml", __dir__)
    workflow = File.read(workflow_path, encoding: "UTF-8")

    assert_includes workflow, '"$EVENT_NAME" == "workflow_dispatch"'
    assert_includes workflow, '"$GITHUB_REF" != "refs/heads/main"'
    assert_includes workflow, "automation_sha:"
    assert_operator workflow.scan("ref: ${{ needs.prepare.outputs.automation_sha }}").length, :>=, 3
    assert_includes workflow, "ref: ${{ needs.prepare.outputs.commit_sha }}"
    assert_includes workflow, '[[ "$actual_release_sha" == "$EXPECTED_RELEASE_SHA" ]]'
    assert_includes workflow, "git merge-base --is-ancestor"
    assert_includes workflow, 'git rev-parse --verify "refs/tags/$RELEASE_TAG^{commit}"'
    assert_includes workflow, "The release tag must point to a commit on main."
    assert_includes workflow, "steps.revision.outputs.build_number"
    assert_includes workflow, "validate-build-number"
    refute_includes workflow, "steps.release.outputs.build_number"
  end
end
