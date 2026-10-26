#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "yaml"
require "tmpdir"
require_relative "test_release_identity"

class ReleaseUpgradeWorkflowTest < Minitest::Test
  def setup
    @workflow = YAML.load_file(File.expand_path("../workflows/testflight-internal.yml", __dir__))
    @jobs = @workflow.fetch("jobs")
  end

  def test_upgrade_script_behavior
    %w[test_release_upgrade.py test_keychain_entitlements.py test_upgrade_journey.py test_upgrade_metadata.py test_upgrade_metal.py].each do |script|
      assert system("python3", File.expand_path(script, __dir__)), "#{script} failed"
    end
  end

  def test_both_platform_archives_finish_before_the_upgrade_gate_and_upload
    assert_includes Array(@jobs.fetch("upgrade").fetch("needs")), "build"
    assert_includes Array(@jobs.fetch("upload").fetch("needs")), "upgrade"
    assert_includes Array(@jobs.fetch("upload").fetch("needs")), "build"
    refute @jobs.fetch("upgrade").key?("if"), "Stable releases and betas both require the gate"
    refute @jobs.fetch("upload").key?("if"), "Upload must use the default successful-needs barrier"
    platforms = IO.popen(["python3", "-c", "import sys; sys.path.insert(0, sys.argv[1]); " \
      "import release_upgrade as r; print(' '.join(r.PLATFORMS))", File.expand_path(__dir__)], &:read).split
    assert_equal %w[iOS macOS], platforms.sort
    build = @jobs.fetch("build").fetch("steps").map { |step| step["run"].to_s }.join("\n")
    assert_includes build, "xcodebuild archive"
    refute_includes build, "altool --upload-package"
    upload = @jobs.fetch("upload").fetch("steps").map { |step| step["run"].to_s }.join("\n")
    assert_includes upload, "altool --upload-package"
    refute_includes upload, "xcodebuild archive"
  end

  # The jobs of the upgrade gate come from the one point list of the journey and the selected sources; a new point
  # or source needs no workflow edit. The generator is tested in test_release_upgrade.py; this checks the wiring.
  def test_the_jobs_of_the_upgrade_gate_are_generated_from_the_point_list_and_the_sources
    journey = File.expand_path("../../scripts/upgrade-test/run_journey.py", __dir__)
    points = IO.popen(["python3", journey, "--list-points"], &:read).split
    assert_equal 12, points.length
    assert_equal points.uniq, points
    matrix = @jobs.fetch("upgrade").dig("strategy", "matrix")
    assert_equal "${{ fromJSON(needs.prepare.outputs.upgrade_matrix) }}", matrix
    assert_equal "${{ steps.upgrade-plan.outputs.upgrade_matrix }}", @jobs.fetch("prepare").fetch("outputs").fetch("upgrade_matrix")
    plan = @jobs.fetch("prepare").fetch("steps").find { |step| step["id"] == "upgrade-plan" }
    refute_nil plan
    generated = IO.popen(["python3", "-c", "import json, sys; sys.path.insert(0, sys.argv[1]); " \
      "import release_upgrade as r; print(json.dumps(r.upgrade_matrix(['a', 'b', 'c'], sys.argv[2].split())))",
                          File.expand_path(__dir__), points.join(" ")], &:read)
    shards = JSON.parse(generated).fetch("include")
    shards.group_by { |shard| shard.fetch("platform") }.each do |platform, group|
      covered = group.flat_map { |shard| shard.fetch("points").split }
      assert_equal points.sort, covered.sort, "#{platform} shards must cover every point exactly once"
    end
    assert_equal shards.length, shards.map { |shard| [shard.fetch("platform"), shard.fetch("shard")] }.uniq.length
    run = @jobs.fetch("upgrade").fetch("steps").find { |step| step["name"] == "Test installed upgrades" }
    assert_equal "${{ matrix.points }}", run.fetch("env").fetch("UPGRADE_POINTS")
    assert_includes run.fetch("run"), '--points "${points[@]}"'
    artifact = @jobs.fetch("upgrade").fetch("steps").find { |step| step["name"] == "Retain upgrade evidence" }
    assert_includes artifact.dig("with", "name"), "${{ matrix.shard }}"
  end

  def test_the_journey_keeps_its_full_log_and_prints_its_results_and_disk
    upgrade = @jobs.fetch("upgrade")
    steps = upgrade.fetch("steps")
    run = steps.find { |step| step["name"] == "Test installed upgrades" }.fetch("run")
    assert_includes run, 'tee "$RUNNER_TEMP/release-upgrade.log"'
    assert_includes run, 'grep --line-buffered -aE "$JOURNEY_LINES" || true'
    lines = Regexp.new(upgrade.fetch("env").fetch("JOURNEY_LINES"))
    ["PASS iOS: v1.0.5 → abc, backup.claimed", "**Upgrade check failed:** The historical app did not reach x",
     "v1.0.5 / x preparation: the UI run started its first test case after 9 s",
     "v1.0.5 / x: case took 400 s, free disk 12.3 GiB", "Free disk after the builds: 20.0 GiB"].each do |line|
      assert_match lines, line
    end
    refute_match lines, "SwiftCompile normal arm64 Compiling Errors.swift"
    disk = steps.find { |step| step["name"] == "Report runner disk" }
    assert_includes disk.fetch("run"), 'df -h "$HOME"'
    assert_includes steps.find { |step| step["name"] == "List upgrade results" }.fetch("run"), 'df -h "$HOME"'
  end

  def test_upgrade_gate_has_no_release_secrets_or_implicit_failure_override
    upgrade = @jobs.fetch("upgrade")
    refute upgrade.key?("environment")
    refute upgrade.key?("continue-on-error")
    upgrade.fetch("steps").each { |step| refute step["continue-on-error"] }
    refute_includes upgrade.to_s, "secrets."
    run = upgrade.fetch("steps").find { |step| step["name"] == "Test installed upgrades" }
    assert_equal "needs.prepare.outputs.upgrade_overridden != 'true'", run.fetch("if")
    assert_includes run.fetch("env").fetch("TARGET_COMMIT"), "needs.prepare.outputs.commit_sha"
    assert_equal "xcode-27", upgrade.fetch("runs-on")
    assert_includes run.fetch("env").fetch("TARGET_RELEASE_TAG"), "needs.prepare.outputs.tag"
    assert_includes run.fetch("run"), '--release-tag "$TARGET_RELEASE_TAG"'
  end

  def test_approved_limits_and_setup_failures_are_always_reported
    steps = @jobs.fetch("upgrade").fetch("steps")
    scope = steps.find { |step| step["name"] == "Report upgrade check scope" }
    refute_nil scope
    assert_equal "always()", scope.fetch("if")
    Dir.mktmpdir do |directory|
      report = File.join(directory, "summary.md")
      assert system({ "GITHUB_STEP_SUMMARY" => report }, "bash", "-c", scope.fetch("run"))
      summary = File.read(report)
      assert_includes summary, "macOS-Keychain-Persistenz über das Update wird nicht im Prüfbau geprüft"
      assert_includes summary, "immediate v1.0.5 Enable-to-SIGKILL"
      assert_includes summary, "CFBundleShortVersionString and CFBundleVersion"
      assert_includes summary, "string-for-string"
      assert_includes summary, "External authentication-header acceptance remains unverified"
    end
    failure = steps.find { |step| step["name"] == "Report blocked release" }
    refute_nil failure
    assert_equal "failure() || cancelled()", failure.fetch("if")
    assert_includes failure.fetch("run"), "Both Apple uploads remain blocked"
    assert_includes failure.fetch("env").fetch("JOURNEY_OUTCOME"), "steps.journey.outcome"
  end

  def test_selection_reads_all_release_pages_and_requires_an_explicit_manual_override
    selection = @jobs.fetch("prepare").fetch("steps").find { |step| step["id"] == "upgrade-plan" }
    refute_nil selection
    assert_includes selection.fetch("run"), "--paginate"
    assert_includes selection.fetch("run"), "--slurp"
    assert_includes selection.fetch("run"), "release_upgrade.py"
    assert_includes selection.fetch("run"), '--override-reason="$OVERRIDE_REASON"'
    inputs = (@workflow["on"] || @workflow.fetch(true)).fetch("workflow_dispatch").fetch("inputs")
    assert inputs.key?("upgrade_override_tag")
    assert inputs.key?("upgrade_override_reason")
    refute inputs.key?("skip_upgrade")
  end
end
