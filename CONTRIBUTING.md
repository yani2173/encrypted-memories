# Contributing to Encrypted Memories

Thank you for helping improve Encrypted Memories. Keep each pull request focused, testable, and safe for all supported Apple platforms.

## Before you start

- Search existing issues and pull requests.
- Open an issue before a large feature or architecture change.
- Never include credentials, private user data, signing files, or local build output.
- You license your contribution under the project's license: the AGPL-3.0 with the additional permission for application stores that the README states.
- PR authors never set app versions, build numbers, release tags, or release notes. Maintainers own releases.
- Coding agents also follow `AGENTS.md`.

## Planning

GitHub issues and milestones hold all planned work. People and coding agents use the same process.

- Each milestone is a release: the next maintenance release, or a feature release such as 1.5 or 2.0.
- Versions follow semantic versioning. A release with a new user-facing feature raises the minor version, for example 1.1.0. A release with only fixes raises the patch version, for example 1.1.1.
- Find the issue before you start. Open one when the work has none.
- Reference the issue in the pull request, for example `Closes #98`.
- Record design decisions and remaining work in the issue, not only in the pull request.
- The `labs` label marks work that ships behind a Labs flag. It stays inert in App Store builds until the maintainers widen the audience.

## Secrets and private data

The repository is public, and a pull request keeps every commit you push, even when a later commit removes a line again.

- Never commit credentials, keys, tokens, certificates, provisioning profiles, or `.env` files.
- Never commit personal data: real names, host names, local paths, device identifiers, or private network addresses. This includes commit metadata.
- Use your GitHub noreply address as commit email, and run `git config --global user.useConfigOnly true`, so Git never derives an address from your machine name.
- CI accepts only the noreply addresses of the account that opens the pull request (`<id>+<login>@users.noreply.github.com` or `<login>@users.noreply.github.com`) and `noreply@github.com` for the committer. A noreply address of another login credits that person's account. Every attribution trailer (`Co-authored-by`, `Signed-off-by`, `Reviewed-by`, `Tested-by`, and similar `-by` keys) must carry the author's own address and must not name a tool.
- Check each commit before you push, not only the final result. CI scans every commit of a pull request, and GitHub push protection blocks known secret formats.

## Architecture rules

- Put shared behavior in `Packages/EncryptedMemoriesKit`.
- Keep platform targets limited to native UI and unavoidable platform adapters.
- Implement each supported feature for macOS, iOS, and iPadOS.
- State an actual platform limitation in the pull request when parity is impossible.
- Do not duplicate business logic across platform targets.
- Prefer a smaller implementation when it preserves behavior and makes regressions less likely.
- Treat `project.yml` as the project source. Do not commit the generated Xcode project.
- Update the pinned SDK patch set when a Proton SDK change modifies vendored code.

The package uses feature modules and shared cores. A feature module owns reusable state, policy, and behavior. The macOS and mobile apps own native presentation and system integration.

## Tests

Every change that alters behavior comes with tests:

- A new feature: unit tests for its shared logic in `Packages/EncryptedMemoriesKit`, and a UI test in `iOSUITests` for each new user action.
- A bug fix: a regression test that fails without the fix and passes with it.
- A refactor without a behavior change: the existing tests stay green. Add a test first when the changed code has none.
- Test behavior through the code under test. Do not add tests that search source files for code text; they break on renames and stay green when the behavior breaks. Module import rules in `CoreArchitectureGateTests` and build-configuration checks in `ProjectHygieneTests` are the exceptions.

## Pull request scope

- Use one pull request for one coherent change.
- Explain the user-visible result and the supported platforms.
- List the tests that you ran.
- Identify any manual check that remains.
- Keep unrelated formatting and refactors out of the pull request.
- Do not weaken a test to hide an application defect.

GitHub runs repository hygiene, Swift style, package tests, iOS app tests, iOS UI tests, and both platform builds. A maintainer reviews the result before merge.

## Own your pull request

You own your pull request until a maintainer merges or closes it. A review can take time, and a fix that is not urgent can wait for a later release.

- Keep your branch current with `main` while the pull request waits.
- Rebase onto `main` when `main` moves on, and resolve every conflict yourself.
- Run the local gates again after a rebase, then push the updated branch.
- Answer review comments and push the requested changes.

## Local verification

Run focused tests while you work. Run these gates before requesting review:

```bash
./scripts/verify-tests.sh
./scripts/verify-ios-app-tests.sh
./scripts/verify-ios-app-tests.sh ui
./scripts/verify-universal-core.sh fast
```

`./scripts/verify-ios-app-tests.sh ui` runs the UI tests. They launch the app in the simulator on an offline test
account and tap through it. They need no Proton account and no network. Add a UI test when you add a user action.

Run the platform shell build when your change affects that app:

```bash
./scripts/verify-macos-app-shell.sh
./scripts/verify-ios-app-shell.sh
```

Use the shared build root documented in the README. Do not create build caches in the repository or `/private/tmp`.

## Automated PR review

The LLM review is advisory. You can merge if it fails, times out, or reports a serious finding,
provided the required checks and repository rules allow the merge.
Never make `Review changed code` a required check or make this workflow a required workflow.
The automation only updates a conversation comment. It never submits an approval or requests changes.
Code links point to the reviewed commit; they do not create unresolved review threads that can block merging.

- Green: no actionable findings in the reviewed changes.
- Yellow: actionable notices without a serious finding.
- Red: serious findings survived evidence verification; this remains advice.
- Grey: review unavailable or incomplete. Unreviewed patch lines, files without a textual patch, model-reported testing gaps, or evidence verification gaps remain. Partial findings also carry a coverage note.

The comment shows at most three findings. Expand the details for evidence and coverage limitations.

The review sends the cumulative pull request diff in bounded batches.
Each request, validation retry, and evidence verification stays at or below 100,000 UTF-8 bytes.
With 8,000 reserved output tokens, this stays below the 131,072-token window measured for Lumo Lite and Max.
A file stays whole when it fits into one request.
A larger file is split at hunk boundaries. A larger hunk is split at line boundaries with an exact `(continued)` hunk header.
Each batch also receives a list of all changed files and short summaries of earlier batches as cross-file context.
If the provider still rejects a batch as too large, the review splits that batch at most twice.
The comment counts text coverage per GitHub patch line, including files beyond the file limit.
For each file, it names the failed, rejected, timed-out, or unstarted batch that left lines unreviewed. It lists up to 40 of these gaps.
Files without a textual patch, such as images, appear in a separate list. The automation does not inspect image or binary content.
Model-reported testing gaps and evidence verification gaps appear in two more lists.
The workflow runs the reviewer from the default branch. A reviewer change takes effect only after it is merged.
A second model pass challenges candidate findings using the patch and redacted source windows
from the exact head and base commits. It checks the trigger, impact, counterevidence, and source quotation.
Missing tests, style preferences, and speculative risks do not justify a serious finding.
Model agreement and a matching quotation cannot prove correctness; human judgment remains necessary.

The review logs activity once per minute without logging response or reasoning text.
Reasoning and answer events count as model output. Transport heartbeats only show connection activity.
Without provider output, the client cannot distinguish silent computation from a stalled model.
It waits ten minutes by default before returning an unavailable review.
Set repository variable `LLM_REVIEW_IDLE_SECONDS` between `120` and `1800` to change this waiting limit.
All model passes and retries share a thirty-minute analysis budget.
The workflow reserves additional time for source reads and comment publication.
The issue-triage workflow keeps its existing shorter timeout policy.

Review coverage is bounded: 80 files, 8 review batches, and 12 review requests, including context splits.
A patch line longer than 24,000 characters is truncated and counts as a coverage gap.
Source reads accept text files up to 200,000 bytes and select windows around candidate lines.
Large inputs can reduce these windows. Omitted patches, unavailable source, and specific missing context produce coverage limitations.
Dismissed suspicions, low-confidence candidates, existing issues, and optional test improvements do not count as coverage gaps.
The model reports optional test improvements as review notes, so they do not change the review status.
Invalid evidence triggers regeneration. Repeated validation failure leaves the lines of that batch as a text coverage gap.
Logs report decision counts without candidate text. An uncertain decision must identify its missing context.
The reviewer does not execute PR code or search the entire repository for callers and tests.
The trusted default-branch script reads PR source as data, including for fork PRs.
Stale runs cannot replace comments for a newer PR snapshot.

Run `python3 .github/scripts/test_review_advisory.py` for evidence-policy and HTTP-stream tests.
Also run the existing review and issue-triage tests when changing their shared client.
Before claiming improved model accuracy, replay maintainer-adjudicated true findings and false positives
through the configured provider. Deterministic tests alone do not establish model accuracy.

The review can also check the architecture rules of this file and the Code section of `AGENTS.md`.
It reads them from the default branch. The repository variable `LLM_REVIEW_REPOSITORY_RULES` set to `1` turns this on.
A rule violation is never blocking.

Maintainers measure a reviewer change with the manual `Replay automated review` workflow.
It runs only from the default branch, because it uses the LLM key. A reviewer change therefore ships behind a switch first.
It reviews the recorded pull request snapshots in `.github/review-replay/cases.json` with and without the rules.
It posts nothing. Its report lists the findings that only one variant reports.
A variant that did not review everything cannot show that a finding is absent; the report marks it incomplete.
Record each verdict in the case file with path, line, severity, title, and `true_finding` or `false_positive`.

References: [GitHub required checks](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches),
[CodeRabbit context verification](https://www.coderabbit.ai/blog/context-engineering-ai-code-reviews).

## Release ownership

A pull request must not set an app version, build number, release tag, or release notes.
After tested changes reach `main`, a maintainer publishes a GitHub Release.

- `v1.2.0-beta.1` and `v1.2.0-rc.1` publish only to internal TestFlight.
- `v1.2.0` submits iOS and macOS to App Review and selects automatic release after approval.

Automation derives one shared Apple build number from the immutable GitHub Release ID and validates it with App Store Connect before starting Xcode. Separate prerelease and stable releases get new builds even on the same source commit. Keep beta tags and their notes unchanged as release history; publish a new stable release instead of renaming a beta. Retrying the same release reuses its build number. Releases through `v1.0.2-beta.3` retain their previously uploaded, commit-derived numbers.

Write owner-written notes under `## English`. This is the only required release-notes section.
Keep notes short and understandable to app users. For a maintenance release, `Bug fixes and performance improvements.` is enough; technical details belong in the pull request.
Without platform subsections, English applies to both platforms.
Optional `### All Platforms`, `### iOS and iPadOS`, and `### macOS` subsections let each platform receive shared text plus its specific text.

`## Deutsch` is optional and uses the same structure. English is used for `de-DE` when German is absent.

Automation sends only extracted owner text to Apple. It never sends contributor names, pull request lists, or generated changelog text.
Contributors have no release-note work.

Before stable replacement, automation waits for both new builds.
It validates both platform plans before it changes either review submission.
It removes lower active review versions independently per platform only in Apple-removable states.
It waits for `DEVELOPER_REJECTED`, updates the same version record, and starts a new review submission.
It does not delete that record or create a fallback for that platform when Apple rejects the update.
It refuses equal or newer active versions or unsafe states.

The manual `External TestFlight` workflow runs from `main` with one published release tag.
It reuses existing builds and never rebuilds or uploads.
It also adds the builds to the internal group, so an external beta is always an internal beta, too.
It enables the public link of the external group and shows the link in the job summary.
It uses the `testflight-external` environment.
`TESTFLIGHT_EXTERNAL_GROUP_NAME` optionally overrides `External Testers`.
Stable and prerelease release tags can be promoted externally.

## Release upgrade verification

The Apple release workflow finishes both distribution builds before it tests installed upgrades.
Both uploads depend on successful upgrade tests on iOS Simulator and macOS.
This gate runs for stable releases and prereleases. It does not add a pull request check.
Full verification runs in the merge queue.

The source list includes every published stable GitHub release from `v1.0.5` onward.
`OLDEST_SUPPORTED_STABLE` in `.github/scripts/release_upgrade.py` defines this lower bound:
1.0.5 was the first public App Store version; earlier releases were admission tests.
A prerelease also checks the previous published beta.
Only `v1.1.0-beta.2` can be excluded, and only as the previous beta.
The job summary states `nicht getestet: v1.1.0-beta.2 (kein Prüfeinstieg)`.
Beta 2 had only testers. The full verification in the merge queue checks the 1.0.5 state fixtures.
Any other predecessor without the test entry or a matching versioned overlay fails the gate.

The test apps use Release optimization and the exact release commit, with
`ENCRYPTED_MEMORIES_UPGRADE_TEST` set only for these separate builds.
The archive and upload configurations never enable the synthetic account.
Storage, migrations, and task algorithms run through their existing implementations.
Only macOS upgrade probes admit devices without Metal 3 under
`#if ENCRYPTED_MEMORIES_UPGRADE_TEST && os(macOS)`; shipping hardware admission stays unchanged.
The journey logs the real Metal devices and their Metal 3 support. It retains the production
grid and all rendered-pixel assertions, so failed rendering still fails the gate.
The macOS journey does not click a visible window of another process at normal or modal-panel level.
A system dialog can cover the app.
Before each Settings click, the journey drags the Settings window by an uncovered title-bar point
until the control keeps 32 points from every foreign window, preferably with the whole window clear.
A covered library control fails the journey.
The pixel checks use a photo that no foreign window covers.
Metadata parity means exact string equality of `CFBundleShortVersionString` and `CFBundleVersion`
with each published GitHub release's authoritative version and build number.
The shared release identity helper and the existing build-number helper supply both archive and probe values.
Each built, cached, and installed probe must match before its old or new journey phase starts.
Evidence records the expected release, source commit, and actual bundle values.
These journeys also verify commit, storage, and task paths. External authentication-header
acceptance remains unverified. Tracked versions and build numbers remain unchanged.
Synthetic photos, inference, and a loopback server replace external inputs and services.
The server records uploads independently of app data. Duplicate uploads fail the journey.
The journey kills the old app during backup claim, remote receipt, and local completion;
model download, install record, and promotion; index embedding and commits; and thumbnail loading and storage.
The new app must load the saved session, retain preferences, and finish the work through the native UI.

The backup journey starts from consent that is already saved on disk.
At the held task boundary, it waits within the existing preparation budget for
`photoBackup.enabled.v1 == true` in the exact owned app container's preferences.
Missing consent or unreadable preferences fail the gate. The task remains held until SIGKILL.
The journey compares the saved consent before the kill, after install-over, and after UI verification.
It neither writes preferences nor enables backup in the replacement app.
The v1.0.5 Enable tap can reach a task boundary before its preference reaches disk;
the immediate tap-to-SIGKILL case is a known historical limit and is not covered by this journey.

Each source runs its own `scripts/update-proton-sdk.sh` in separate source and SDK scratch directories.
The `v1.0.5` overlay is pinned to its published commit and must apply cleanly.
Later releases carry their inactive test entry and require no overlay, with one exception:
`v1.1.0-beta.3` predates the hosted Metal admission, so its pinned overlay adds only that test-only admission.
Only completed builds enter the cache, keyed by source, toolchain, architecture, platform, and test-build inputs.
A typical cold run needs two app builds per platform; cached historical products remove one build per source.
Release metadata also keys the cache,
so distinct releases on one commit cannot reuse the wrong version or build number.

On the hosted runner one iOS case takes about seven minutes, so the iOS gate runs in two jobs.
Each job tests every source with half of the interruption points; together they cover the same cases as one job.
Each UI run gets up to 600 seconds to start its first test case. The 180-second preparation budget starts
when the first test case starts, when the old app reaches its checkpoint on its own, or when the UI run ends, whichever comes first.
The 240-second verification budget starts with the first test case or the end of the run.
A slow UI runner start on a loaded runner therefore cannot use up either budget.
Each iOS job holds six points per source. With three sources, a job needs about 145 minutes of its 180;
a fourth source needs a third iOS job.
A failing case keeps the app's system log. The evidence also holds the runner load, the free disk and the size of
the large build and Simulator directories, and each case's timing and free disk.
The job summary shows the free disk at the start and the end. The journey step prints only result, timing and disk
lines, because GitHub cuts a step log at about 10 MB; the full output stays in the retained `release-upgrade.log`.
A historical source keeps only its published app; its build scratch is deleted after the build.

The iOS journey installs the new app with `simctl install` over the existing app.
It never removes the app or resets its data between the old and new phases.
It runs on the Simulator runtime pinned in `IOS_RUNTIME` of `scripts/upgrade-test/run_journey.py` (iOS 27.0, build 24A434).
A missing, ambiguous, unavailable, or different runtime fails before a device exists; the message names the expected and the installed build.
The new phase does not seed a session: loss of the real simulator Keychain entry fails the journey.
The seed marker records both the loopback server URL and the case-specific account UID.
A validated case identifier contains exactly 32 ASCII hexadecimal characters (`0-9`, `a-f`, `A-F`); its maximum length is 32.
The test entry rejects every other identifier with an explicit error before it can become an account path component.
A changed case or server, or an old URL-only marker, requires a new seed.
An unchanged case and server retain the existing session.
The native seed regression uses `UPGRADE_NATIVE_SEED_TARGET=HEAD`, `UPGRADE_NATIVE_WORKING_COPY=1`,
and `UPGRADE_RELEASE_TAG` set to an existing published release for the candidate metadata
with `.github/scripts/test_upgrade_journey.py UpgradeJourneyTests.test_native_seed_identity_survives_restarts_and_reseeds_changed_cases_or_servers`.
Set `UPGRADE_NATIVE_SEED_PLATFORM=iOS` to include the old-format file in a fresh owned simulator container.
The default macOS run also checks that an unchanged identity preserves the saved session contents.
The opt-in simulator-isolation regression also passes `UPGRADE_RELEASE_TAG` explicitly.
Both regressions require published metadata even when the source is an untagged working-copy revision.
Both macOS installations use one temporary self-signed identity, without release credentials.
Only the synthetic macOS session persists outside the Data Protection Keychain.
Production Keychain access groups must match the last supported stable release.

macOS-Keychain-Persistenz über das Update wird nicht im Prüfbau geprüft; abgedeckt durch iOS-Simulator und Entitlement-Vergleich.

For a local rehearsal, run these commands through the configured shared build queue:

```bash
bash scripts/test-release-upgrade.sh --target HEAD --release-tag "$CANDIDATE_RELEASE_TAG" --sources v1.0.5 --platform iOS --working-copy
bash scripts/test-release-upgrade.sh --target HEAD --release-tag "$CANDIDATE_RELEASE_TAG" --sources v1.0.5 --platform macOS --working-copy
```

Set `CANDIDATE_RELEASE_TAG` to an existing published app release. The local working-copy rehearsal
uses that release's metadata and reports its separate source identity; it is not a shipping artifact.
Without `--working-copy`, the source commit must match the published tag. Missing or mismatched
GitHub releases fail; no project fallback supplies metadata.
These commands create no release or tag and perform no Apple upload.
They use only an owned simulator and the macOS host. Never install them on a physical iPhone or iPad.
Omit `--working-copy` to test an exact committed revision.
Use `--points` with one or more named interruption points for focused diagnosis.
Logs, UI result bundles, and the server ledger remain under the shared build root's `UpgradeCheck/evidence` directory.
The release workflow uses trusted default-branch automation, so its changes take effect after merge.

A failed upgrade stops both uploads and records its cause in the job summary.
A maintainer can retry the run after fixing the cause.
To deliberately override the gate, dispatch `Apple release` from `main` with an existing published
`release_tag`, the same value in `upgrade_override_tag`, and a nonempty `upgrade_override_reason`.
The summary records the override and its reason. Automatic release events cannot override the gate.

## iPhone Duo verification

Build with Xcode 27.1 or newer and install the iOS 27.1 simulator runtime before selecting iPhone Duo.
`project.yml` keeps the existing deployment targets. The selected Xcode supplies the SDK;
do not pin a versioned `SDKROOT` or a machine-specific Xcode path.

Select the full Xcode toolchain with `DEVELOPER_DIR`, then use the existing test scripts:

```bash
export IOS_TEST_DESTINATION="platform=iOS Simulator,name=iPhone Duo,OS=latest"
./scripts/verify-ios-app-tests.sh
./scripts/verify-ios-app-tests.sh ui
unset IOS_TEST_DESTINATION
```

The override is optional. Without it, the scripts keep selecting an installed iPhone simulator.
A named override selects the newest matching runtime. `OS=27` matches 27.x; `OS=27.1` matches
27.1 and 27.1.x. A three-component value such as `OS=27.1.0` matches exactly, with missing runtime
components treated as zero. An omitted OS or `OS=latest` selects the newest runtime.
OS values must use `latest` or one to three numeric components. Invalid OS values, empty `id=` or
`OS=` fields, and fields without `=` fail with exit 64. Simulator names containing a comma are not
supported; use `id=` for those devices. An `id=` override selects an existing simulator directly.
Both test modes wait for that simulator
to boot and pass the same device ID to Xcode. `build-for-testing` does not boot a simulator.
Command tests cover these choices in `.github/scripts/test_ios_test_commands.py`.

The Duo simulator starts on its outer display. Set the fully open, book, and tabletop poses in
Device Hub before their runs. XCTest and `simctl` have no fold or pose command in Xcode 27.1.
Rotation uses the documented `XCUIDevice.orientation` property; rotation does not open the inner display.
Record the actual pose and orientation for each result. Do not label a window resize as a display handoff.
Fold and unfold during grid, viewer, selection, and search flows remain manual checks.

An explicit Duo baseline can expose existing failures without changing the default simulator run.
List each failure, its evidence, and its owning issue in the pull request. Keep every existing assertion;
correct the underlying behavior or test assumption in its owning change.

Hosted CI uses the Xcode installed on its runner image. A Duo run needs Xcode 27.1, the matching
simulator runtime, and a Duo simulator. A workflow change must select the installed toolchain and
update the expected Xcode version together. Keep the merge queue and required checks unchanged.

References: [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo),
[Device Hub interaction](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub),
and [XCUIDevice.orientation](https://developer.apple.com/documentation/xcuiautomation/xcuidevice/orientation).
