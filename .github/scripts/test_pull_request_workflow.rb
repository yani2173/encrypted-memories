require "minitest/autorun"
require "yaml"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "timeout"

class PullRequestWorkflowTests < Minitest::Test
  WORKFLOWS = File.expand_path("../workflows", __dir__)
  REQUIRED_CHECKS = [
    "Repository hygiene", "Swift style", "Swift package tests", "iOS app tests",
    "Shared architecture", "macOS app shell", "iOS app shell", "iOS UI tests"
  ].freeze

  def setup
    @workflow = YAML.load_file(File.join(WORKFLOWS, "pull-request.yml"))
  end

  def evaluate(expression, context)
    return expression unless expression.is_a?(String)

    # These workflow expressions contain only context lookups and boolean operators.
    source = expression.sub(/\A\$\{\{\s*/, "").sub(/\s*\}\}\z/, "")
    source = source.gsub("always()", "true").gsub("!cancelled()", "true")
    source = source.gsub(/(?:github|inputs|runner|needs)\.[a-z_.\-]+/) { |path| context.fetch(path, nil).inspect }
    eval(source)
  end

  def diff_steps
    @workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps") }
      .select { |step| step.fetch("env", {}).key?("BASE_SHA") }
  end

  def test_merge_queue_runs_all_required_checks
    assert_equal ["checks_requested"], (@workflow["on"] || @workflow.fetch(true)).fetch("merge_group").fetch("types")
    jobs = @workflow.fetch("jobs").values
    REQUIRED_CHECKS.each do |name|
      job = jobs.find { |candidate| candidate["name"] == name }
      refute_nil job, name
      assert job["if"].nil? || evaluate(job["if"], {"github.event_name" => "merge_group"}), name
    end
  end

  WORKER_JOBS = %w[
    repository-hygiene package-verification ios-verification ios-ui-verification macos-verification
  ].freeze
  WATCHDOG = "cancel-on-failure"
  # Stops a run whose merge-queue entry is gone (issue #717); it is a watchdog too, not a result job.
  SUPERSEDED_WATCHDOG = "cancel-superseded-run"
  # Runs only for pull requests, so the queue watchdog never waits for it; it is a worker, not a result job.
  PULL_REQUEST_ONLY_WORKERS = %w[swift-style-linux].freeze

  def watchdog
    @workflow.fetch("jobs").fetch(WATCHDOG)
  end

  def test_only_the_queue_watchdogs_may_write_actions_and_run_no_code_of_the_pull_request
    assert_equal({"contents" => "read"}, @workflow.fetch("permissions"))
    jobs = @workflow.fetch("jobs")
    jobs.each do |name, job|
      scopes = job.fetch("permissions", {})
      if name == WATCHDOG
        assert_equal({"actions" => "write"}, scopes, "the watchdog has no other scope, also no contents")
      elsif name == SUPERSEDED_WATCHDOG
        assert_equal({"actions" => "write", "contents" => "read"}, scopes,
                     "the superseded-run watchdog writes only actions and reads only contents")
      else
        refute scopes.key?("actions"), "#{name} must not request an actions scope"
        assert_empty scopes.values - %w[read], "#{name} stays read-only"
      end
    end
    # Only inline shell: no checkout, no action, no script of the pull request.
    steps = watchdog.fetch("steps")
    assert_equal 1, steps.length
    assert_empty steps.first.keys - %w[name env run]
    refute_match(%r{\./|scripts/|\.github/|\bbash \S+\.sh|\bsource\b|\bcurl\b}, steps.first.fetch("run"))
    environment = {"GH_TOKEN" => "${{ github.token }}", "GH_REPO" => "${{ github.repository }}"}
    assert_equal environment, steps.first.fetch("env")
    # No result job waits for a watchdog, and no watchdog is a required check.
    [WATCHDOG, SUPERSEDED_WATCHDOG].each do |watchdog_id|
      jobs.each { |name, job| refute_includes Array(job["needs"]), watchdog_id, name }
      refute_includes REQUIRED_CHECKS, jobs.fetch(watchdog_id).fetch("name"), watchdog_id
    end
    assert_equal "ubuntu-24.04", watchdog.fetch("runs-on")
    # The longest queue run took 123 minutes. The loop ends before the job limit, which stays below the 180 minute
    # check timeout of the queue.
    limit = watchdog.fetch("timeout-minutes")
    assert_operator limit, :>=, 150
    assert_operator limit, :<=, 180
    assert_operator watchdog.fetch("steps").first.fetch("run")[/deadline=\$\(\(SECONDS \+ (\d+)\)\)/, 1].to_i, :<, limit * 60
    {"merge_group" => true, "pull_request" => false, "workflow_dispatch" => false}.each do |event, expected|
      assert_equal expected, evaluate(watchdog.fetch("if"), {"github.event_name" => event}), event
    end
  end

  def test_the_watchdog_reads_the_jobs_of_its_run_and_cancels_that_run_only
    script = watchdog.fetch("steps").first.fetch("run")
    assert_includes script, %q(gh api "repos/$GH_REPO/actions/runs/$GITHUB_RUN_ID/jobs" --paginate)
    assert_includes script, %q(gh run cancel "$GITHUB_RUN_ID")
    assert_includes script, "while (( SECONDS < deadline )); do"
    assert_equal 1, script.scan("gh run cancel").length
    assert_equal 1, script.scan("gh api").length
    # The jobs that end the watch are the worker jobs of this workflow.
    names = WORKER_JOBS.map { |id| @workflow.fetch("jobs").fetch(id).fetch("name") }
    listed = script[/^workers=\((.*)\)$/, 1].scan(/"([^"]+)"/).flatten
    assert_equal names, listed
    assert_includes script, %(own="#{watchdog.fetch('name')}")
  end

  # The second watchdog stops a run whose merge-queue entry is gone (issue #717). It must not run code of the pull
  # request either: it has no checkout, and its decision script is read from the base commit of the merge group.
  def test_the_superseded_run_watchdog_reads_only_trusted_code_and_cancels_only_its_own_run
    job = @workflow.fetch("jobs").fetch(SUPERSEDED_WATCHDOG)
    assert_equal "Cancel a superseded queue run", job.fetch("name")
    {"merge_group" => true, "pull_request" => false, "workflow_dispatch" => false}.each do |event, expected|
      assert_equal expected, evaluate(job.fetch("if"), {"github.event_name" => event}), event
    end
    assert_equal "ubuntu-24.04", job.fetch("runs-on")
    limit = job.fetch("timeout-minutes")
    assert_operator limit, :>=, 150
    assert_operator limit, :<=, 180
    steps = job.fetch("steps")
    assert_equal 1, steps.length
    step = steps.first
    assert_empty step.keys - %w[name env run]
    environment = {"GH_TOKEN" => "${{ github.token }}", "GH_REPO" => "${{ github.repository }}",
                   "SCRIPT_SHA" => "${{ github.event.merge_group.base_sha }}",
                   "HEAD_SHA" => "${{ github.event.merge_group.head_sha }}"}
    assert_equal environment, step.fetch("env")
    script = step.fetch("run")
    # No checkout and no action: the decision script is read from the base commit of the merge group, never from
    # the head of the pull request. For a later entry that base commit is the head of the entry ahead.
    assert_match(%r{repos/\$GH_REPO/contents/\.github/scripts/cancel_superseded_queue_run\.py\?ref=\$SCRIPT_SHA}, script)
    # The fetch of the decision script is bounded: a hung read must not hold the job for its whole limit.
    assert_match(/limit gh api "repos\/\$GH_REPO\/contents\//, script)
    assert_includes script, %q(timeout 60 "$@")
    assert_includes script, %q(--head-sha "$HEAD_SHA")
    assert_includes script, %q(--run-id "$GITHUB_RUN_ID")
    assert_equal 1, script.scan("python3").length
    # The jobs that make a run finishing are the worker jobs of this workflow.
    names = WORKER_JOBS.map { |id| @workflow.fetch("jobs").fetch(id).fetch("name") }
    listed = script.scan(/--worker "([^"]+)"/).flatten
    assert_equal names, listed
    # The job can never fail: the failure watchdog of the run cancels the run when any job of it fails.
    assert_match(/\|\| echo/, script)
    assert_includes script, "exit 0"
    # The decision script and its tests live in the repository and run in the hygiene job.
    assert File.exist?(File.expand_path("cancel_superseded_queue_run.py", __dir__))
    hygiene = @workflow.fetch("jobs").fetch("repository-hygiene").fetch("steps")
                       .find { |s| s["name"] == "Test GitHub automation" }
    assert_includes hygiene.fetch("run"), "python3 .github/scripts/test_cancel_superseded_queue_run.py"
  end

  # Runs the real step of the superseded-run watchdog with a fake `gh`. The fetch and the decode of the
  # decision script run for real. The first queue read lists `entry_oids`, every later read lists `later_oids`.
  # A `sitecustomize` makes the real script skip its 60 second waits, and every case ends by itself.
  def run_superseded_watchdog(entry_oids:, worker_status:, later_oids: nil, contents_ok: true, cancel_exit: 0,
                              cancel_message: "")
    step = @workflow.fetch("jobs").fetch(SUPERSEDED_WATCHDOG).fetch("steps").first
    script = File.expand_path("cancel_superseded_queue_run.py", __dir__)
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      Dir.mkdir(bin)
      File.write(File.join(dir, "script.sh"), step.fetch("run"))
      [["queue.0.json", entry_oids], ["queue.1.json", later_oids || entry_oids]].each do |file, oids|
        nodes = oids.map { |oid| {"state" => "BUILDABLE", "headCommit" => {"oid" => oid}} }
        File.write(File.join(dir, file),
                   JSON.generate([{"data" => {"repository" => {"mergeQueue" => {"entries" => {"nodes" => nodes}}}}}]))
      end
      File.write(File.join(dir, "sitecustomize.py"), "import time\ntime.sleep = lambda seconds: None\n")
      rows = WORKER_JOBS.map do |id|
        {"name" => @workflow.fetch("jobs").fetch(id).fetch("name"), "status" => worker_status, "conclusion" => nil}
      end
      File.write(File.join(dir, "jobs.json"), JSON.generate([{"jobs" => rows}]))
      File.write(File.join(bin, "gh"), <<~SH)
        #!/usr/bin/env bash
        args="$*"
        if [[ "$1 $2" == "run cancel" ]]; then
          echo "$3" >> "#{dir}/cancelled"
          [[ -z "#{cancel_message}" ]] || echo "#{cancel_message}" >&2
          exit "#{cancel_exit}"
        fi
        if [[ "$args" == *"contents/.github/scripts/cancel_superseded_queue_run.py"* ]]; then
          [[ #{contents_ok} == true ]] || { echo "HTTP 404" >&2; exit 1; }
          base64 < "#{script}"
          exit 0
        fi
        if [[ "$args" == *graphql* ]]; then
          n=$(cat "#{dir}/queue-reads" 2>/dev/null || echo 0)
          echo $((n + 1)) > "#{dir}/queue-reads"
          cat "#{dir}/queue.$((n > 0 ? 1 : 0)).json"
          exit 0
        fi
        if [[ "$args" == */jobs* ]]; then
          cat "#{dir}/jobs.json"
          exit 0
        fi
        echo "2026-01-01T00:00:00Z"
      SH
      FileUtils.chmod(0o755, File.join(bin, "gh"))
      env = {"PATH" => "#{bin}:#{ENV.fetch('PATH')}", "GH_REPO" => "owner/repo", "GITHUB_RUN_ID" => "4242",
             "GH_TOKEN" => "unused", "RUNNER_TEMP" => dir.to_s, "SCRIPT_SHA" => "0" * 40, "HEAD_SHA" => "f" * 40,
             "PYTHONPATH" => dir.to_s}
      out, status = Timeout.timeout(30) { Open3.capture2e(env, "bash", File.join(dir, "script.sh")) }
      cancelled = File.exist?(File.join(dir, "cancelled")) ? File.read(File.join(dir, "cancelled")).split : []
      [status.exitstatus, cancelled, out]
    end
  end

  def test_the_superseded_watchdog_ends_green_and_cancels_only_the_own_run
    # The entry was in the queue and is gone, the run is old, and the workers run: one cancel of the own run,
    # then the job ends green.
    status, cancelled, out = run_superseded_watchdog(entry_oids: ["f" * 40], later_oids: ["e" * 40],
                                                    worker_status: "in_progress")
    assert_equal [0, ["4242"]], [status, cancelled]
    assert_includes out, "The run is cancelled."
    # Every worker is complete: the run merged or is finishing, so nothing is cancelled.
    status, cancelled, out = run_superseded_watchdog(entry_oids: ["e" * 40, "f" * 40], worker_status: "completed")
    assert_equal [0, []], [status, cancelled]
    assert_includes out, "All worker jobs finished without a failure."
    # A cancel of an already ended run counts as a success.
    status, cancelled, = run_superseded_watchdog(entry_oids: ["f" * 40], later_oids: ["e" * 40],
                                                worker_status: "in_progress",
                                                cancel_exit: 1, cancel_message: "HTTP 409: already completed")
    assert_equal [0, ["4242"]], [status, cancelled]
    # A failed fetch of the decision script ends green and cancels nothing.
    status, cancelled, out = run_superseded_watchdog(entry_oids: ["e" * 40], worker_status: "in_progress",
                                                    contents_ok: false)
    assert_equal [0, []], [status, cancelled]
    assert_includes out, "is not readable"
  end

  # Runs the real script of the watchdog with a fake `gh` and no waiting. Each element of `responses` is the answer
  # of one jobs query: an Array of [name, status, conclusion] rows, or :error.
  def run_watchdog(responses, cancel_exit: 0, cancel_message: "")
    script = watchdog.fetch("steps").first.fetch("run")
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      Dir.mkdir(bin)
      File.write(File.join(dir, "script.sh"), script)
      responses.each_with_index do |response, index|
        jobs = response == :error ? [] : response.map do |name, status, conclusion|
          {"name" => name, "status" => status, "conclusion" => conclusion.empty? ? nil : conclusion}
        end
        File.write(File.join(dir, "response.#{index}"), JSON.generate({"jobs" => jobs}))
        File.write(File.join(dir, "error.#{index}"), response == :error ? "1" : "0")
      end
      File.write(File.join(bin, "gh"), <<~SH)
        #!/usr/bin/env bash
        if [[ "$1 $2" == "run cancel" ]]; then
          echo "$3" >> "#{dir}/cancelled"
          [[ -z "${FAKE_CANCEL_MESSAGE:-}" ]] || echo "$FAKE_CANCEL_MESSAGE" >&2
          exit "${FAKE_CANCEL_EXIT:-0}"
        fi
        n=$(cat "#{dir}/calls" 2>/dev/null || echo 0)
        echo $((n + 1)) > "#{dir}/calls"
        i=$((n < #{responses.length} ? n : #{responses.length} - 1))
        if [[ "$(cat "#{dir}/error.$i")" == 1 ]]; then echo "HTTP 502" >&2; exit 1; fi
        # The real filter of the script runs on the JSON of the API.
        filter=""
        while [[ $# -gt 0 ]]; do if [[ "$1" == "--jq" ]]; then filter="$2"; fi; shift; done
        jq -r "$filter" "#{dir}/response.$i"
      SH
      # A script that never ends is stopped after 40 waits, so a broken loop fails the test instead of hanging it.
      File.write(File.join(bin, "sleep"), <<~SH)
        #!/usr/bin/env bash
        echo "$1" >> "#{dir}/slept"
        if [[ $(wc -l < "#{dir}/slept") -ge 40 ]]; then kill -9 "$PPID"; fi
      SH
      FileUtils.chmod(0o755, [File.join(bin, "gh"), File.join(bin, "sleep")])
      env = {"PATH" => "#{bin}:#{ENV.fetch('PATH')}", "GH_REPO" => "owner/repo", "GITHUB_RUN_ID" => "4242",
             "GH_TOKEN" => "unused", "FAKE_CANCEL_EXIT" => cancel_exit.to_s,
             "FAKE_CANCEL_MESSAGE" => cancel_message}
      _out, status = Timeout.timeout(20) { Open3.capture2e(env, "bash", File.join(dir, "script.sh")) }
      cancelled = File.exist?(File.join(dir, "cancelled")) ? File.read(File.join(dir, "cancelled")).split : []
      calls = File.exist?(File.join(dir, "calls")) ? File.read(File.join(dir, "calls")).to_i : 0
      @waits = File.exist?(File.join(dir, "slept")) ? File.read(File.join(dir, "slept")).split : []
      [status.exitstatus, cancelled, calls]
    end
  end

  def workers(status:, conclusion: "success")
    WORKER_JOBS.map do |id|
      [@workflow.fetch("jobs").fetch(id).fetch("name"), status, status == "completed" ? conclusion : ""]
    end
  end

  def test_the_watchdog_cancels_on_the_first_failed_job_and_ends_when_the_workers_finish
    own = ["Cancel a queue run after a failure", "in_progress", ""]
    running = workers(status: "in_progress")
    failed_ui = workers(status: "in_progress").tap { |rows| rows[3] = [rows[3][0], "completed", "failure"] }
    # A failure: one cancel of this run, then the job ends.
    status, cancelled, calls = run_watchdog([running + [own], failed_ui + [own]])
    assert_equal [0, ["4242"], 2], [status, cancelled, calls]
    # A failed result job counts as well.
    result = ["Swift package tests", "completed", "failure"]
    assert_equal ["4242"], run_watchdog([running + [own, result]])[1]
    # All workers done without a failure: no cancel.
    status, cancelled, = run_watchdog([running + [own], workers(status: "completed") + [own]])
    assert_equal [0, []], [status, cancelled]
    # Cancelled or skipped jobs are not failures.
    cancelled_rows = workers(status: "completed").tap do |rows|
      rows[1..].each_index { |index| rows[index + 1] = [rows[index + 1][0], "completed", "cancelled"] }
    end + [own]
    assert_equal [0, []], run_watchdog([cancelled_rows]).first(2)
    # The own job never counts, also when it shows a failure.
    own_failed = ["Cancel a queue run after a failure", "completed", "failure"]
    assert_equal [0, []], run_watchdog([workers(status: "completed") + [own_failed]]).first(2)
    # A worker job that is not listed yet keeps the watch going until it appears.
    partial = workers(status: "completed").first(3) + [own]
    status, cancelled, calls = run_watchdog([partial, partial, workers(status: "completed") + [own]])
    assert_equal [0, [], 3], [status, cancelled, calls]
    assert_equal %w[30 30], @waits, "every wait is 30 seconds"
  end

  def test_the_watchdog_survives_api_errors_and_a_failing_cancel
    own = ["Cancel a queue run after a failure", "in_progress", ""]
    failed = workers(status: "completed", conclusion: "failure") + [own]
    status, cancelled, calls = run_watchdog([:error, :error, failed])
    assert_equal [0, ["4242"], 3], [status, cancelled, calls]
    assert_equal ["30", "30"], @waits.first(2), "every wait is 30 seconds"
    # A cancel request that fails ends the job red (the job is not required), also without a second attempt, unless
    # the run is already cancelled or completed.
    status, cancelled, = run_watchdog([failed], cancel_exit: 1, cancel_message: "HTTP 500")
    assert_equal [1, ["4242"]], [status, cancelled]
    status, cancelled, = run_watchdog([failed], cancel_exit: 1, cancel_message: "HTTP 409: Cannot cancel a workflow run that is completed")
    assert_equal [0, ["4242"]], [status, cancelled]
    # A read that keeps failing ends red after 20 attempts, so that nothing silently watches nothing.
    status, cancelled, calls = run_watchdog([:error])
    assert_equal [1, [], 20], [status, cancelled, calls]
    # A hygiene job that ended without success (a timeout is a cancelled job) cancels the run too; a manual cancel
    # of the whole run finds an already cancelled run and ends without an error.
    hygiene_timeout = workers(status: "in_progress").tap { |rows| rows[0] = [rows[0][0], "completed", "cancelled"] }
    assert_equal ["4242"], run_watchdog([hygiene_timeout + [own]])[1]
  end

  def test_every_result_job_runs_also_when_a_worker_job_is_cancelled
    results = @workflow.fetch("jobs").reject do |id, _|
      WORKER_JOBS.include?(id) || PULL_REQUEST_ONLY_WORKERS.include?(id) ||
        [WATCHDOG, SUPERSEDED_WATCHDOG].include?(id)
    end
    PULL_REQUEST_ONLY_WORKERS.each do |id|
      refute evaluate(@workflow.fetch("jobs").fetch(id).fetch("if"), {"github.event_name" => "merge_group"}), id
    end
    refute_empty results
    results.each do |id, job|
      assert_includes job.fetch("if").to_s, "always()", "#{id}: a cancelled run must still produce a failing check"
      refute_empty job.fetch("needs"), id
    end
  end

  def test_a_pull_request_is_checked_for_style_on_linux_and_every_other_event_on_the_macos_runner
    jobs = @workflow.fetch("jobs")
    linux = jobs.fetch("swift-style-linux")
    macos = jobs.fetch("package-verification")
    result = jobs.fetch("code-quality")
    assert_equal "ubuntu-24.04", linux.fetch("runs-on")
    assert_equal "Swift style", result.fetch("name")
    assert_includes REQUIRED_CHECKS, result.fetch("name")
    refute_includes REQUIRED_CHECKS, linux.fetch("name")
    {"pull_request" => [true, false], "merge_group" => [false, true], "workflow_dispatch" => [false, true]}
      .each do |event, (on_linux, on_macos)|
        context = {"github.event_name" => event}
        assert_equal on_linux, evaluate(linux.fetch("if"), context), "Linux job, #{event}"
        assert_equal on_macos, macos.fetch("if", "${{ true }}").then { |condition| evaluate(condition, context) }, "macOS job, #{event}"
      end
    assert_equal %w[package-verification swift-style-linux], result.fetch("needs").sort
    assert_equal "${{ always() }}", result.fetch("if")
    # The result job takes the verdict of the job that ran for the event, and nothing else.
    step = result.fetch("steps").first
    assert_equal({"EVENT" => "${{ github.event_name }}", "LINUX_RESULT" => "${{ needs.swift-style-linux.outputs.style }}",
                  "MACOS_RESULT" => "${{ needs.package-verification.outputs.style }}"}, step.fetch("env"))
    verdicts = ["", "success", "failure", "skipped"]
    {"pull_request" => "LINUX_RESULT", "merge_group" => "MACOS_RESULT", "workflow_dispatch" => "MACOS_RESULT"}
      .each do |event, decisive|
        verdicts.product(verdicts).each do |linux_verdict, macos_verdict|
          env = {"EVENT" => event, "LINUX_RESULT" => linux_verdict, "MACOS_RESULT" => macos_verdict}
          _out, status = Open3.capture2e(env, "bash", "-c", step.fetch("run"))
          expected = env.fetch(decisive) == "success"
          assert_equal expected, status.success?, "#{event}: Linux #{linux_verdict.inspect}, macOS #{macos_verdict.inspect}"
        end
      end
    [linux, macos].each do |job|
      style = job.fetch("steps").find { |step| step["id"] == "style" }
      assert_equal "bash scripts/verify-swift-style.sh", style.fetch("run")
      assert_equal "${{ steps.style.outcome }}", job.fetch("outputs").fetch("style")
    end
    # The pinned tools: a hash for every download, and the SwiftLint version of the macOS action.
    install = linux.fetch("steps").find { |step| step["name"] == "Install the Swift toolchain and SwiftLint" }
    env = install.fetch("env")
    assert_match(/\A\h{64}\z/, env.fetch("SWIFT_SHA256"))
    assert_match(/\A\h{64}\z/, env.fetch("SWIFTLINT_SHA256"))
    script = install.fetch("run")
    # Each download is checked by a hash that fails the step, before anything is unpacked, over https only.
    checks = script.lines.select { |line| line.include?("sha256sum") }
    assert_equal 2, checks.length
    checks.each { |line| assert_match(/\A\s*echo "\$\{?\w+\}?  \$RUNNER_TEMP\/\S+" \| sha256sum --check\n?\z/, line) }
    assert script.index("sha256sum").to_i < script.index("tar -xzf")
    assert script.index("sha256sum", script.index("swiftlint.zip\" ")) < script.index("unzip")
    assert_match(/\Aset -euo pipefail/, script)
    assert_equal 2, script.scan("--proto '=https' --proto-redir '=https'").length
    assert_equal 2, script.scan("--max-time").length
    assert_equal 2, script.scan("--retry 3").length
    refute_match(/latest/i, script)
    action = YAML.load_file(File.join(WORKFLOWS, "../actions/install-swiftlint/action.yml"))
    assert_equal action.fetch("runs").fetch("steps").first.fetch("env").fetch("SWIFTLINT_VERSION"), env.fetch("SWIFTLINT_VERSION")
    style = linux.fetch("steps").find { |step| step["id"] == "style" }
    assert_equal "${{ runner.temp }}/swift/usr/lib", style.fetch("env").fetch("LINUX_SOURCEKIT_LIB_PATH")
    refute_nil style.fetch("env").fetch("SWIFT_FORMAT_EXECUTABLE")
    refute_nil style.fetch("env").fetch("SWIFTLINT_EXECUTABLE")
  end

  def test_every_diff_step_uses_event_commits
    refute_empty diff_steps
    contexts = [
      [{"github.event.pull_request.base.sha" => "pr-base", "github.event.pull_request.head.sha" => "pr-head", "github.sha" => "merge"}, "pr-base", "pr-head"],
      [{"github.event.merge_group.base_sha" => "queue-base", "github.event.merge_group.head_sha" => "queue-head", "github.sha" => "merge"}, "queue-base", "queue-head"],
      [{"github.sha" => "dispatch-head"}, nil, "dispatch-head"]
    ]
    diff_steps.each do |step|
      contexts.each do |context, base, head|
        actual_base = evaluate(step["env"]["BASE_SHA"], context)
        base.nil? ? assert_nil(actual_base, step["name"]) : assert_equal(base, actual_base, step["name"])
        assert_equal head, evaluate(step["env"]["HEAD_SHA"], context), step["name"]
      end
    end
  end

  def concurrency(context)
    @workflow.fetch("concurrency").fetch("group").gsub(/\$\{\{.*?\}\}/) { |expression| evaluate(expression, context).to_s }
  end

  def test_queue_groups_do_not_cancel_each_other_or_pull_requests
    queue = {"github.event_name" => "merge_group", "github.event.merge_group.head_sha" => "queue-one"}
    other_queue = queue.merge("github.event.merge_group.head_sha" => "queue-two")
    pr = {"github.event_name" => "pull_request", "github.event.pull_request.number" => 42}
    refute_equal concurrency(queue), concurrency(other_queue)
    refute_equal concurrency(queue), concurrency(pr)
    refute evaluate(@workflow["concurrency"]["cancel-in-progress"], queue)
    assert evaluate(@workflow["concurrency"]["cancel-in-progress"], pr)
    assert_equal concurrency(pr), concurrency(pr.merge("github.sha" => "new-head"))
  end

  def test_other_workflows_stay_outside_the_queue
    Dir[File.join(WORKFLOWS, "*.yml")].each do |path|
      next if File.basename(path) == "pull-request.yml"
      refute (YAML.load_file(path)["on"] || YAML.load_file(path).fetch(true)).key?("merge_group"), File.basename(path)
    end
  end
  def test_full_verification_uses_four_mac_runners_without_hygiene_waits
    mac_jobs = @workflow.fetch("jobs").select { |_, job| job["runs-on"] == "xcode-27" }
    assert_equal ["ios-ui-verification", "ios-verification", "macos-verification", "package-verification"], mac_jobs.keys.sort
    mac_jobs.each_value { |job| refute job.key?("needs") }
  end

  def test_queue_guard_runs_only_for_pull_requests
    guard = @workflow.fetch("jobs").fetch("repository-hygiene").fetch("steps")
      .find { |step| step["run"].to_s.include?("require_merge_queue.py") }
    refute_nil guard
    assert evaluate(guard.fetch("if"), {"github.event_name" => "pull_request"})
    ["merge_group", "workflow_dispatch"].each do |event|
      refute evaluate(guard.fetch("if"), {"github.event_name" => event})
    end
    assert_includes guard.fetch("run"), '"$GITHUB_REPOSITORY"'
  end

  def test_pull_requests_skip_heavy_apple_jobs_but_keep_style
    jobs = @workflow.fetch("jobs")
    ["ios-verification", "macos-verification"].each do |id|
      condition = jobs.fetch(id).fetch("if")
      refute evaluate(condition, {"github.event_name" => "pull_request"})
      ["merge_group", "workflow_dispatch"].each do |event|
        assert evaluate(condition, {"github.event_name" => event})
      end
    end
    # The style of a pull request runs on Linux (swift-style-linux); the macOS job runs it with the tests in the queue.
    package = jobs.fetch("package-verification")
    refute evaluate(package.fetch("if"), {"github.event_name" => "pull_request"})
    tests = package.fetch("steps").find { |step| step["id"] == "tests" }
    refute evaluate(tests.fetch("if"), {"github.event_name" => "pull_request"})
  end

  def test_simulator_build_includes_both_test_bundles
    project = YAML.load_file(File.join(WORKFLOWS, "../../project.yml"))
    scheme = project.fetch("schemes").fetch("EncryptedMemoriesMobileCI")
    assert_equal ["EncryptedMemoriesMobileTests", "EncryptedMemoriesMobileUITests"], scheme.fetch("test").fetch("targets")
  end

  def test_xcode_cache_measurement_has_only_one_writer
    ios = @workflow.fetch("jobs").fetch("ios-verification").fetch("steps")
      .find { |step| step["uses"] == "./.github/actions/prepare-apple-build" }
    macos = @workflow.fetch("jobs").fetch("macos-verification").fetch("steps")
      .find { |step| step["uses"] == "./.github/actions/prepare-apple-build" }
    assert_equal "false", macos.fetch("with").fetch("save-cache")
    refute macos.fetch("with").fetch("measure-cache", false)
    # A queue run saves nothing: its cache would belong to its own temporary branch, which no other run reads.
    package = @workflow.fetch("jobs").fetch("package-verification").fetch("steps")
      .find { |step| step["uses"] == "./.github/actions/prepare-apple-build" }
    [ios, package].each do |step|
      saves = step.fetch("with").fetch("save-cache")
      {"merge_group" => false, "workflow_dispatch" => true}.each do |event, expected|
        assert_equal expected, evaluate(saves, {"github.event_name" => event}), "#{event}: #{saves}"
      end
    end
    assert_includes ios.fetch("with").fetch("measure-cache"), "inputs.measure_cache"
    action = YAML.load_file(File.join(WORKFLOWS, "../actions/prepare-apple-build/action.yml"))
    ["Save resolved SwiftPM dependencies", "Save resolved Xcode dependencies"].each do |name|
      save = action.fetch("runs").fetch("steps").find { |step| step["name"] == name }
      assert_includes save.fetch("if"), "inputs.save-cache != 'false'", name
    end
  end

  def test_failed_ui_jobs_retain_the_complete_result_bundle
    steps = @workflow.fetch("jobs").fetch("ios-ui-verification").fetch("steps")
    ui = steps.find { |step| step["id"] == "ui" }
    upload = steps.find { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
    refute_nil upload, "A failed UI job must retain its result bundle"
    assert_equal "failure()", upload.fetch("if")
    inputs = upload.fetch("with")
    assert_equal ui.fetch("env").fetch("IOS_TEST_RESULT_BUNDLE_PATH"), inputs.fetch("path")
    assert_equal true, inputs.fetch("include-hidden-files")
    assert_equal "warn", inputs.fetch("if-no-files-found")
    assert_equal 7, inputs.fetch("retention-days")
    assert_includes inputs.fetch("name"), "github.run_id"
    assert_includes inputs.fetch("name"), "github.run_attempt"
  end

  def test_the_ui_job_retries_only_a_runner_bootstrap_failure_and_keeps_the_gate_exact
    job = @workflow.fetch("jobs").fetch("ios-ui-verification")
    steps = job.fetch("steps")
    ui = steps.find { |step| step["id"] == "ui" }
    wrapper = "bash .github/scripts/run_ui_tests_with_retry.sh"
    assert_equal "#{wrapper} bash ./scripts/verify-ios-app-tests.sh ui", ui.fetch("run")
    %w[continue-on-error shell working-directory].each { |key| refute ui.key?(key), "The UI step must not set #{key}" }
    [@workflow["env"], job["env"], ui["env"]].compact.each do |env|
      refute env.key?("UI_TEST_MAX_RETRIES"), "The workflow keeps the retry count of the script"
    end
    assert_equal "${{ steps.ui.outcome }}", job.fetch("outputs").fetch("ui")
    # The wrapper keeps the first attempt next to this bundle, under the name that the upload step collects.
    assert_equal "${{ runner.temp }}/ios-ui.xcresult", ui.fetch("env").fetch("IOS_TEST_RESULT_BUNDLE_PATH")
    assert_equal 90, job.fetch("timeout-minutes")
    # The runner state is informational: it never decides the result, and it runs at the start and at the end.
    start = steps.find { |step| step["name"] == "Record the runner state at the start" }
    finish = steps.find { |step| step["name"] == "Record the runner state at the end" }
    assert_equal "bash .github/scripts/runner_state.sh start", start.fetch("run")
    assert_equal "bash .github/scripts/runner_state.sh end", finish.fetch("run")
    assert_equal "${{ !cancelled() }}", start.fetch("if")
    assert_equal "always()", finish.fetch("if")
    [start, finish].each do |step|
      assert_equal true, step.fetch("continue-on-error")
      assert_equal 2, step.fetch("timeout-minutes")
    end
    prepare = steps.index { |step| step["uses"] == "./.github/actions/prepare-apple-build" }
    assert_operator steps.index(start), :<, prepare
    assert_operator steps.index(finish), :>, steps.index(ui)
    # The first attempt's bundle and log are kept when a retry happened, even if the second attempt passes.
    failed = steps.find { |step| step["name"] == "Retain failed UI test results" }
    kept = steps.find { |step| step["name"] == "Retain the result of the first attempt after a retry" }
    assert_equal "${{ always() && steps.ui.outputs.retried == 'true' }}", kept.fetch("if")
    assert_equal failed.fetch("uses"), kept.fetch("uses")
    # A failed upload of the first attempt must not turn a passing retry red.
    assert_equal true, kept.fetch("continue-on-error")
    assert_includes kept.fetch("with").fetch("name"), "github.run_id"
    assert_includes kept.fetch("with").fetch("name"), "github.run_attempt"
    assert_includes kept.fetch("with").fetch("path"), "ios-ui-attempt1.xcresult"
    assert_includes kept.fetch("with").fetch("path"), "ios-ui-attempt1.log"
    # The bash test of the wrapper runs in the hygiene job.
    hygiene_steps = @workflow.fetch("jobs").fetch("repository-hygiene").fetch("steps")
    hygiene = hygiene_steps.find { |step| step["name"] == "Test GitHub automation" }
    assert_includes hygiene.fetch("run"), "bash .github/scripts/test_run_ui_tests_with_retry.sh"
  end

  def test_both_simulator_jobs_start_the_simulator_before_the_dependencies_and_never_depend_on_it
    %w[ios-verification ios-ui-verification].each do |name|
      job = @workflow.fetch("jobs").fetch(name)
      steps = job.fetch("steps")
      boot = steps.find { |step| step.dig("env", "IOS_TEST_ACTION") == "boot-simulator" }
      refute_nil boot, "#{name} must start the simulator"
      assert_equal "bash ./scripts/verify-ios-app-tests.sh", boot.fetch("run"), name
      # The test step reads the record of the start step and shuts down a device that it does not test.
      record = "${{ runner.temp }}/simulator-udid"
      assert_equal record, boot.fetch("env").fetch("IOS_TEST_BOOT_RECORD"), name
      test_step = steps.find { |step| step.dig("env", "IOS_TEST_ACTION") == "test-without-building" }
      assert_equal record, test_step.fetch("env").fetch("IOS_TEST_BOOT_RECORD"), name
      # A failed start never fails the job: the test run boots the simulator itself, as before.
      assert_equal true, boot.fetch("continue-on-error"), name
      assert_equal 2, boot.fetch("timeout-minutes"), name
      refute boot.key?("id"), "No step may depend on the start of the simulator in #{name}"
      assert_nil boot["if"], name
      # The boot runs while the dependencies and the test bundles build.
      prepare = steps.index { |step| step["uses"] == "./.github/actions/prepare-apple-build" }
      build = steps.index { |step| step.dig("env", "IOS_TEST_ACTION") == "build-for-testing" }
      assert_operator steps.index(boot), :<, prepare, name
      assert_operator steps.index(boot), :<, build, name
      job.fetch("outputs", {}).each_value { |value| refute_includes value, boot.fetch("name"), name }
      steps.each { |step| refute_includes step["if"].to_s, "Start the simulator", name }
    end
  end

  def test_the_test_steps_keep_a_result_bundle_so_that_a_run_without_tests_fails
    {"ios-verification" => ["tests", "ios-hosted.xcresult"], "ios-ui-verification" => ["ui", "ios-ui.xcresult"]}
      .each do |name, (id, bundle)|
      step = @workflow.fetch("jobs").fetch(name).fetch("steps").find { |candidate| candidate["id"] == id }
      env = step.fetch("env")
      assert_equal "test-without-building", env.fetch("IOS_TEST_ACTION"), name
      assert_equal "1", env.fetch("IOS_TEST_PREPARED"), name
      # The script counts the executed tests in this bundle and fails the step when there are none.
      assert_equal "${{ runner.temp }}/#{bundle}", env.fetch("IOS_TEST_RESULT_BUNDLE_PATH"), name
    end
  end

  def diagnostic_steps
    steps = @workflow.fetch("jobs").fetch("ios-ui-verification").fetch("steps")
    [steps.find { |step| step["name"] == "Configure UI latency diagnostics" },
      steps.find { |step| step["id"] == "ui" },
      steps.find { |step| step["name"] == "Retain UI latency diagnostics" }]
  end

  # A deliberate, narrow exception to "do not search source files in tests": this CI contract finds the darwin-only
  # Python tests, so a new one cannot skip silently on Ubuntu. It reads decorator statements only, also when a
  # decorator is split over lines; parentheses inside its strings would confuse the line counting.
  # skipUnless(platform is darwin) and skipIf(platform is not darwin) mean "only on macOS"; skipIf(platform is darwin)
  # means "not on macOS" and needs no macOS step.
  def darwin_only_guard?(statement)
    unless_darwin = statement.match?(/skipUnless/) && statement.match?(/(==\s*|startswith\()["']darwin/i)
    if_not_darwin = statement.match?(/skipIf/) && statement.match?(/!=\s*["']darwin/i)
    unless_darwin || if_not_darwin
  end

  def darwin_guards(root)
    Dir[File.join(root, ".github/scripts/test_*.py"), File.join(root, "scripts/tests/test_*.py")].flat_map do |path|
      lines = File.readlines(path, encoding: "UTF-8")
      script = path.delete_prefix("#{root}/")
      guards = []
      index = 0
      while index < lines.length
        if lines[index] =~ /\A\s*@.*skip/i
          start = index
          statement = lines[index].dup
          depth = statement.count("(") - statement.count(")")
          while depth > 0 && index + 1 < lines.length
            index += 1
            statement << lines[index]
            depth += lines[index].count("(") - lines[index].count(")")
          end
          if darwin_only_guard?(statement)
            target = lines[(index + 1)..].find { |candidate| candidate =~ /\A\s*(def|class) \w+/ }
            flunk "#{script}:#{start + 1}: a darwin skip guard is followed by no class or method" if target.nil?
            kind, symbol = target.match(/\A\s*(def|class) (\w+)/).captures
            guards << [script, start + 1, kind, symbol]
          end
        end
        index += 1
      end
      guards
    end
  end

  def test_darwin_only_script_tests_run_in_the_macos_job_and_the_queue_requires_them
    jobs = @workflow.fetch("jobs")
    macos = jobs.fetch("macos-verification")
    steps = macos.fetch("steps")
    probes = steps.find { |step| step["id"] == "upgrade-probes" }
    refute_nil probes, "The macOS job must run the tests that skip themselves on other systems"
    # A darwin-only test class or method skips itself on Ubuntu, so only this macOS step can run it.
    root = File.expand_path("../..", __dir__)
    commands = probes.fetch("run").lines.map(&:strip)
    assert_includes commands, "set -euo pipefail"
    assert_empty commands.grep(/\|\||;|&|#/), "A probe command must not mask its exit status or run in the background"
    assert commands.drop(1).all? { |command| command.match?(%r{\Apython3 (\.github/scripts|scripts/tests)/test_\w+\.py\b}) },
      "The probe step may contain only the shell option line and the Python test commands"
    guards = darwin_guards(root)
    assert_operator guards.length, :>=, 2
    guards.each do |script, line, kind, symbol|
      pattern = if kind == "class"
        /\Apython3 #{Regexp.escape(script)}\z/ # A guarded class runs as part of its whole file.
      else
        /\Apython3 #{Regexp.escape(script)} .*\b#{Regexp.escape(symbol)}\b/
      end
      assert commands.any? { |command| command.match?(pattern) },
        "#{script}:#{line}: #{kind} #{symbol} is darwin-only but the macOS job does not run it"
    end
    checkout = steps.find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
    refute_nil checkout, "The macOS job must check out the source"
    assert_equal 0, checkout.fetch("with").fetch("fetch-depth"), "The Metal test reads pinned releases by tag"
    python = steps.find { |step| step["id"] == "python" }
    refute_nil python, "The macOS job must set up Python before the probes"
    # The exact conditions: a cancelled run reports nothing, and no earlier failure may hide the probe result.
    assert_equal "${{ !cancelled() }}", python.fetch("if")
    assert_equal "${{ !cancelled() && steps.python.outcome == 'success' }}", probes.fetch("if")
    # The same pinned action and version as the upgrade gate that runs on the same image.
    upgrade_python = YAML.load_file(File.join(WORKFLOWS, "testflight-internal.yml")).fetch("jobs").fetch("upgrade")
      .fetch("steps").find { |step| step["id"] == "python" }
    assert_match(/\Aactions\/setup-python@[0-9a-f]{40}\z/, python.fetch("uses"))
    assert_equal upgrade_python.fetch("uses"), python.fetch("uses")
    assert_equal upgrade_python.fetch("with").fetch("python-version"), python.fetch("with").fetch("python-version")
    assert_operator steps.index(python), :<, steps.index(probes)
    assert_equal "${{ steps.upgrade-probes.outcome }}", macos.fetch("outputs").fetch("upgrade_probes")
    gate_job = jobs.fetch("macos-app-shell")
    assert_equal "macOS app shell", gate_job.fetch("name"), "The gate must stay the required check of that name"
    gate = gate_job.fetch("steps").find { |step| step.fetch("env", {}).key?("RESULT") &&
      step.fetch("env").fetch("RESULT").include?("upgrade_probes") }
    refute_nil gate, "The macOS gate must require the probe result"
    assert_equal "${{ needs.macos-verification.outputs.upgrade_probes }}", gate.fetch("env").fetch("RESULT")
    assert_equal 'test "$RESULT" = success', gate.fetch("run")
    assert_equal "${{ always() }}", gate.fetch("if"), "The probe result must report even when the app shell check fails"
    assert_includes gate_job.fetch("needs"), "macos-verification"
    # Without always(), a failing macOS job would skip the gate and the required check would never be evaluated.
    assert_equal "${{ always() && github.event_name != 'pull_request' }}", gate_job.fetch("if")
    # A shell or directory template could run nothing and still report success.
    [["probe step", probes], *gate_job.fetch("steps").map { |step| ["macOS gate step #{step["name"]}", step] }].each do |name, item|
      %w[shell working-directory].each { |key| refute item.key?(key), "The #{name} must not set #{key}" }
    end
    [["workflow", @workflow], ["macOS job", macos], ["macOS gate job", gate_job]].each do |name, item|
      refute item.key?("defaults"), "The #{name} must not set default run options"
    end
    # continue-on-error would turn a failed step into an "outcome" of success for the gate.
    { "macOS job" => macos, "Python step" => python, "probe step" => probes, "macOS gate job" => gate_job }
      .merge(gate_job.fetch("steps").to_h { |step| ["macOS gate step #{step["name"]}", step] }).each do |name, item|
      refute item.key?("continue-on-error"), "The #{name} must not set continue-on-error"
    end
  end

  def test_ui_diagnostics_default_to_disabled
    inputs = (@workflow["on"] || @workflow.fetch(true)).fetch("workflow_dispatch").fetch("inputs")
    diagnostics = inputs.fetch("collect_ui_diagnostics", {})
    assert_equal "boolean", diagnostics["type"]
    assert_equal false, diagnostics["default"]
  end

  def test_ui_diagnostics_skip_default_and_non_dispatch_runs
    configure, ui, upload = diagnostic_steps
    refute ui.fetch("env").key?("IOS_TEST_DIAGNOSTICS_PATH"), "The test command must not enable collection unconditionally"
    refute_nil configure
    ["pull_request", "merge_group", "workflow_dispatch"].each do |event|
      [nil, false, true].each do |opt_in|
        next if event == "workflow_dispatch" && opt_in == true
        context = {"github.event_name" => event, "inputs.collect_ui_diagnostics" => opt_in}
        refute evaluate(configure.fetch("if"), context), "Unexpected collector for #{event}, opt-in #{opt_in.inspect}"
        refute evaluate(upload.fetch("if"), context), "Unexpected upload for #{event}, opt-in #{opt_in.inspect}"
      end
    end
  end

  def test_ui_diagnostics_collect_and_retain_only_on_opted_in_dispatch
    configure, ui, upload = diagnostic_steps
    refute_nil configure
    refute_nil upload
    context = {"github.event_name" => "workflow_dispatch", "inputs.collect_ui_diagnostics" => true}
    assert evaluate(configure.fetch("if"), context)
    assert evaluate(upload.fetch("if"), context)
    assert_equal true, configure["continue-on-error"], "Diagnostic setup errors must not fail the UI job"
    assert_equal true, upload.fetch("continue-on-error")
    assert_equal 7, upload.fetch("with").fetch("retention-days")
    assert_equal "warn", upload.fetch("with").fetch("if-no-files-found")
    Dir.mktmpdir("ui-diagnostic-workflow") do |directory|
      context["runner.temp"] = directory
      environment_file = File.join(directory, "github-env")
      variables = configure.fetch("env").transform_values do |value|
        value.gsub(/\$\{\{.*?\}\}/) { |expression| evaluate(expression, context).to_s }
      end
      output, status = Open3.capture2e(variables.merge("GITHUB_ENV" => environment_file), "bash", "-c", configure.fetch("run"))
      assert status.success?, output
      exported = File.readlines(environment_file, chomp: true).to_h { |line| line.split("=", 2) }
      expected_path = upload.fetch("with").fetch("path").gsub(/\$\{\{.*?\}\}/) { |expression| evaluate(expression, context).to_s }
      assert_equal expected_path, exported.fetch("IOS_TEST_DIAGNOSTICS_PATH")
      refute ui.fetch("env").key?("IOS_TEST_DIAGNOSTICS_PATH"), "The test command must retain the conditional exported value"
    end
  end


  def reviewed_xcode_action
    YAML.load_file(File.join(WORKFLOWS, "../actions/prepare-apple-build/action.yml"))
  end

  def run_reviewed_xcode_check(output, exit_code: 0, directory_present: true, stderr_output: "")
    action = reviewed_xcode_action
    step = action.fetch("runs").fetch("steps").find { |s| s.fetch("name", "").start_with?("Check the pinned Xcode") }
    Dir.mktmpdir do |directory|
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(bin)
      developer = File.join(directory, "SelectedXcode.app", "Contents", "Developer")
      FileUtils.mkdir_p(developer) if directory_present
      calls = File.join(directory, "xcode-calls")
      executable = File.join(bin, "xcodebuild")
      File.write(executable, "#!/bin/bash\nprintf 'call\\n' >> \"$XCODE_CALLS\"\nprintf '%s' \"$FAKE_XCODE_OUTPUT\"\nprintf '%s' \"$FAKE_XCODE_STDERR\" >&2\nexit \"$FAKE_XCODE_EXIT\"\n")
      FileUtils.chmod(0o755, executable)
      environment_file = File.join(directory, "environment")
      environment = {
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "DEVELOPER_DIR" => developer,
        "EXPECTED_XCODE_VERSION" => action.fetch("inputs").fetch("xcode-version").fetch("default"),
        "EXPECTED_XCODE_BUILD" => action.fetch("inputs").fetch("xcode-build", {}).fetch("default", ""),
        "GITHUB_ENV" => environment_file, "GITHUB_STEP_SUMMARY" => File.join(directory, "summary"),
        "XCODE_CALLS" => calls, "FAKE_XCODE_OUTPUT" => output, "FAKE_XCODE_EXIT" => exit_code.to_s, "FAKE_XCODE_STDERR" => stderr_output
      }
      stdout, stderr, status = Open3.capture3(environment, "bash", "-c", step.fetch("run"),
        chdir: File.expand_path("../..", WORKFLOWS))
      yield stdout, stderr, status, File.exist?(calls),
        (File.exist?(environment_file) ? File.read(environment_file) : ""), developer
    end
  end

  def test_reviewed_xcode_check_accepts_exact_version_and_build
    run_reviewed_xcode_check("Xcode 27.1\nBuild version 27A9275\n") do |stdout, stderr, status, called, exports, developer|
      assert status.success?, stderr
      assert called
      assert_includes stdout, "Build version 27A9275"
      assert_equal "DEVELOPER_DIR=#{developer}\n", exports
    end
  end

  def test_reviewed_xcode_check_rejects_wrong_or_missing_version_and_build
    ["Xcode 27.0\nBuild version 27A9275\n", "Xcode 27.1\nBuild version 27A9269\n",
     "Xcode 27.2\nBuild version 27B48\n", "Xcode 27.1\n", "Build version 27A9275\n", ""].each do |output|
      run_reviewed_xcode_check(output) do |_stdout, stderr, status, called, exports, _developer|
        refute status.success?, output.inspect
        assert called
        assert_includes stderr, "expected '27.1' build '27A9275'"
        assert_empty exports
      end
    end
  end

  def test_reviewed_xcode_check_rejects_a_failed_command_and_missing_directory
    run_reviewed_xcode_check("Xcode 27.1\nBuild version 27A9275\n", exit_code: 7) do |_out, err, status, called, exports, _dir|
      refute status.success?
      assert called
      assert_includes err, "xcodebuild -version failed"
      assert_empty exports
    end
    run_reviewed_xcode_check("Xcode 27.1\nBuild version 27A9275\n", directory_present: false) do |_out, err, status, called, exports, _dir|
      refute status.success?
      refute called
      assert_includes err, "developer directory is missing"
      assert_empty exports
    end
  end

  # Runs a shell body from the repository root with a fake xcodebuild that reports `output`.
  def run_with_fake_xcodebuild(body, output, extra_env = {})
    Dir.mktmpdir do |directory|
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(bin)
      developer = File.join(directory, "SelectedXcode.app", "Contents", "Developer")
      FileUtils.mkdir_p(developer)
      calls = File.join(directory, "xcode-calls")
      executable = File.join(bin, "xcodebuild")
      File.write(executable, "#!/bin/bash\nprintf 'call\\n' >> \"$XCODE_CALLS\"\nprintf '%s' \"$FAKE_XCODE_OUTPUT\"\n")
      FileUtils.chmod(0o755, executable)
      github_output = File.join(directory, "github-output")
      environment = {
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "DEVELOPER_DIR" => developer, "GITHUB_OUTPUT" => github_output,
        "XCODE_CALLS" => calls, "FAKE_XCODE_OUTPUT" => output,
        # nil removes the variable, so an expectation that a case omits is unset, not inherited from the test run.
        "EXPECTED_XCODE_VERSION" => nil, "EXPECTED_XCODE_BUILD" => nil
      }.merge(extra_env)
      stdout, stderr, status = Open3.capture3(environment, "bash", "-c", body, chdir: File.expand_path("../..", WORKFLOWS))
      yield stdout, stderr, status, File.exist?(calls), (File.exist?(github_output) ? File.read(github_output) : "")
    end
  end

  def test_toolchain_script_rejects_an_empty_or_missing_expectation
    pins = reviewed_xcode_action.fetch("inputs")
    version = pins.fetch("xcode-version").fetch("default")
    build = pins.fetch("xcode-build").fetch("default")
    output = "Xcode #{version}\nBuild version #{build}\n"
    [{ "EXPECTED_XCODE_VERSION" => "", "EXPECTED_XCODE_BUILD" => build },
     { "EXPECTED_XCODE_VERSION" => version, "EXPECTED_XCODE_BUILD" => "" },
     { "EXPECTED_XCODE_VERSION" => "", "EXPECTED_XCODE_BUILD" => "" },
     { "EXPECTED_XCODE_BUILD" => build },
     { "EXPECTED_XCODE_VERSION" => version },
     {}].each do |expectation|
      run_with_fake_xcodebuild("bash .github/scripts/verify_xcode_toolchain.sh", output, expectation) do |_out, err, status, called, _key|
        refute status.success?, expectation.inspect
        refute called, expectation.inspect
        assert_includes err, "EXPECTED_XCODE_VERSION or EXPECTED_XCODE_BUILD is missing or empty"
      end
    end
    # A value of only whitespace is no pin either: it never equals the reported version or build.
    [{ "EXPECTED_XCODE_VERSION" => " ", "EXPECTED_XCODE_BUILD" => build },
     { "EXPECTED_XCODE_VERSION" => version, "EXPECTED_XCODE_BUILD" => " " },
     { "EXPECTED_XCODE_VERSION" => "\t", "EXPECTED_XCODE_BUILD" => "\n" }].each do |expectation|
      run_with_fake_xcodebuild("bash .github/scripts/verify_xcode_toolchain.sh", output, expectation) do |_out, err, status, _called, _key|
        refute status.success?, expectation.inspect
        assert_includes err, "expected '"
      end
    end
    run_with_fake_xcodebuild("bash .github/scripts/verify_xcode_toolchain.sh", output,
      "EXPECTED_XCODE_VERSION" => version, "EXPECTED_XCODE_BUILD" => build) do |_out, err, status, called, _key|
      assert status.success?, err
      assert called
    end
  end

  def test_the_action_inputs_are_the_only_place_that_writes_the_expected_xcode
    pins = reviewed_xcode_action.fetch("inputs")
    version = pins.fetch("xcode-version").fetch("default")
    build = pins.fetch("xcode-build").fetch("default")
    script = File.read(File.join(WORKFLOWS, "../scripts/verify_xcode_toolchain.sh"))
    refute_includes script, build
    refute_includes script, version
    upgrade = YAML.load_file(File.join(WORKFLOWS, "testflight-internal.yml")).fetch("jobs").fetch("upgrade").fetch("steps")
    toolchain = upgrade.find { |step| step["id"] == "toolchain" }
    refute_includes toolchain.fetch("run"), build
    refute_includes toolchain.fetch("run"), version
    # The upgrade job has no copy of the pins: it reads the action's defaults, so a changed pin reaches it.
    run_with_fake_xcodebuild(toolchain.fetch("run"), "Xcode #{version}\nBuild version #{build}\n") do |_out, err, status, called, key|
      assert status.success?, err
      assert called
      assert_match(/\Akey=\h{64}-\S+\n\z/, key)
    end
    run_with_fake_xcodebuild(toolchain.fetch("run"), "Xcode #{version}\nBuild version 27A0000\n") do |_out, err, status, _called, key|
      refute status.success?
      assert_includes err, "expected '#{version}' build '#{build}'"
      assert_empty key
    end
  end

  def test_hosted_workflows_select_the_reviewed_xcode_and_upgrade_checks_before_cache
    developer = "/Applications/Xcode_27.1.app/Contents/Developer"
    %w[pull-request.yml testflight-internal.yml dependency-cache.yml].each do |name|
      workflow = YAML.load_file(File.join(WORKFLOWS, name))
      assert_equal developer, workflow.fetch("env").fetch("DEVELOPER_DIR"), name
    end
    action = reviewed_xcode_action
    assert_equal "27.1", action.fetch("inputs").fetch("xcode-version").fetch("default")
    assert_equal "27A9275", action.fetch("inputs").fetch("xcode-build").fetch("default")
    check = action.fetch("runs").fetch("steps").find { |step| step.fetch("name", "").start_with?("Check the pinned Xcode") }
    assert_equal developer, check.fetch("env").fetch("DEVELOPER_DIR")
    package = @workflow.fetch("jobs").fetch("package-verification").fetch("steps")
    assert_equal "sudo xcode-select --switch /Applications/Xcode_27.1.app",
      package.find { |step| step.fetch("name", "").start_with?("Select Xcode") }.fetch("run")
    upgrade = YAML.load_file(File.join(WORKFLOWS, "testflight-internal.yml")).fetch("jobs").fetch("upgrade").fetch("steps")
    toolchain = upgrade.find { |step| step["id"] == "toolchain" }
    assert_includes toolchain.fetch("run"), "bash .github/scripts/verify_xcode_toolchain.sh"
    assert_operator upgrade.index(toolchain), :<, upgrade.index { |step| step["id"] == "cache" }
    cache_inputs = action.fetch("runs").fetch("steps").find { |step| step["id"] == "dependency-cache-key" }.fetch("run")
    assert_includes cache_inputs, ".github/scripts/verify_xcode_toolchain.sh"
    assert_includes cache_inputs, '$xcode_version-$xcode_build'
    warm = YAML.load_file(File.join(WORKFLOWS, "dependency-cache.yml"))
    events = warm["on"] || warm.fetch(true)
    assert_includes events.fetch("push").fetch("paths"), ".github/scripts/verify_xcode_toolchain.sh"
  end

  def test_reviewed_xcode_check_retains_stdout_and_stderr_when_command_fails
    stdout_marker = "xcodebuild stdout diagnostic before failure"
    stderr_marker = "xcodebuild stderr diagnostic before failure"
    run_reviewed_xcode_check("#{stdout_marker}\n", exit_code: 7, stderr_output: "#{stderr_marker}\n") do |stdout, stderr, status, called, exports, _developer|
      refute status.success?
      assert called
      assert_includes stderr, stderr_marker
      assert_includes stderr, "xcodebuild -version failed"
      assert_empty exports
      assert_includes stdout, stdout_marker
    end
  end
end
