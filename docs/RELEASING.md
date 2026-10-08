# Releasing Sashimi

How a build reaches TestFlight. One click — the **Release** workflow — bumps the
version, tags and deploys tvOS, iOS and Mac. The rest of this page is what it does
and what to do when it doesn't.

For one-time account, certificate and App Store Connect setup, see
[APP_STORE_DEPLOYMENT.md](APP_STORE_DEPLOYMENT.md). This document covers only the
recurring release flow.

---

## The short version

**Actions → Release → Run workflow** (on `main`), or:

```bash
gh workflow run release.yml                                   # next patch, beta1, all platforms
gh workflow run release.yml -f version=1.6.41 -f beta=1 \
  -f notes='• Up Next countdown now plays the next episode\n• Home updates after watching elsewhere'
gh workflow run release.yml -f version=1.6.36 -f beta=2 -f tvos=false -f macos=false   # iOS-only re-release
gh workflow run release.yml --ref <branch> -f dry_run=true     # rehearse: builds + signs, ships nothing
```

| Input | Default | Meaning |
|-------|---------|---------|
| `version` | next patch after `main` | `X.Y.Z`. Equal to `main`'s version = re-release, no bump. |
| `beta` | `1` | Tags end `-betaN`. |
| `tvos` / `ios` / `macos` | all on | Platforms to ship. |
| `notes` | generated | TestFlight "What to Test" for every platform, verbatim; `\n` = new line. |
| `dry_run` | off | No PR, merge, tags or uploads. Bumps on a throwaway branch and builds + signs each platform. |

What it does, in order:

1. **Bump.** Runs `scripts/bump-version.sh X.Y.Z` (all three `MARKETING_VERSION`s),
   pushes `release/vX.Y.Z`, opens a PR and queues it (`gh pr merge --auto`). Waits
   for the merge — the PR goes through the same required checks and merge queue as
   any other. Skipped when `main` is already at `X.Y.Z`.
2. **Tag** the merge commit for the selected platforms: `vX.Y.Z-betaN` (tvOS),
   `ios-vX.Y.Z-betaN`, `mac-vX.Y.Z-betaN`. Refuses tags that already exist.
3. **Deploy** by *calling* `deploy.yml`, `deploy-ios.yml` and `deploy-mac.yml`
   (`workflow_call`) with that commit and tag, in parallel. Each shows up as a job
   of the Release run.

### Automatic: every merge ships

`auto-release.yml` presses Release for you. On each push to `main` it:

1. skips the Release workflow's own bump merge (`chore: X.Y.Z (#N)`) and merges
   that change no app code since the last `v*-beta*` tag — only `Sashimi/`,
   `SashimiMobile/`, `Shared/`, `TopShelf/`, `Vendor/`, `project.yml` and
   `Package.*` count, so docs/tests/CI/fastlane changes ship nothing;
2. waits 15 minutes — a newer merge cancels the wait and starts its own, so a
   burst of merges ships as one build;
3. starts the Release workflow with the defaults (next patch, beta 1, all three
   platforms, generated notes).

To pause it: Actions → Auto release → ⋯ → Disable workflow. The Release button
still works either way.

The tags are pushed with `GITHUB_TOKEN` on purpose: GitHub starts no workflows for
pushes made with it, so the tag-triggered deploys don't fire a second time. The
Release workflow deploys explicitly instead of hoping a tag push triggers
something — a laptop going to sleep, a quoting slip or a merge race can't half-ship
a release any more.

### One secret to add: `RELEASE_TOKEN`

Branch protection only takes changes through PRs, and a PR opened with the
built-in `GITHUB_TOKEN` **never triggers CI** (GitHub suppresses workflow runs for
events it causes), so its required checks would never report and it would never
merge. The bump PR is therefore opened with a personal token:

- **Settings → Developer settings → Fine-grained tokens → Generate**
- Resource owner `bitstorm-labs`, repository access: only `sashimi-apple`
- Permissions: **Contents: Read and write**, **Pull requests: Read and write**
- Save it as the repository secret **`RELEASE_TOKEN`**
  (`gh secret set RELEASE_TOKEN -R bitstorm-labs/sashimi-apple`)

Dry runs don't need it. Without it a real release stops at step 1 with a clear
error. (A GitHub App installation token would work the same and doesn't expire.)

### Every deploy checks its version

All three deploy workflows run `scripts/check-version.sh <tag>` first and refuse to
build if `project.yml`'s `MARKETING_VERSION` (all three entries) doesn't equal the
version in the tag — e.g. `ios-v1.6.41-beta1` on a commit still at 1.6.40.

---

## Tags still work by hand

| Tag | Workflow | What happens |
|-----|----------|--------------|
| `v1.4.1-beta1` / `v1.4.1-rc1` | `deploy.yml` | **tvOS → TestFlight** |
| `ios-v1.4.1-beta1` / `ios-v1.4.1-rc1` | `deploy-ios.yml` | **iOS/iPad → TestFlight** |
| `mac-v1.4.1-beta1` | `deploy-mac.yml` | **macOS → TestFlight** |
| `v1.4.1` (plain) | — | **Nothing.** |

Hand-pushed tags ship **one platform each** — push every platform's tag (or use the
Release workflow, which does). `release-parity.yml` warns (no longer fails) when a
hand-pushed tvOS/iOS tag has no counterpart within 10 minutes; a deliberate
one-platform re-release such as `ios-v1.6.36-beta2` is fine.

A plain `vX.Y.Z` tag used to run an archive-only workflow and ship nothing (on
2026-08-10 v1.2.14 was "released" that way and no TestFlight build appeared). That
workflow is gone; `release.yml` is now the Release workflow above.

Confirm the deploy actually ran:

```bash
gh run list --limit 5 --json workflowName,headBranch,status \
  --jq '.[] | "\(.workflowName) [\(.headBranch)] \(.status)"'
```

---

## tvOS, iOS and Mac are three pipelines

One app (Universal Purchase, shared bundle id `com.mondominator.sashimi`,
distinguished by platform), three workflows, three tag namespaces. `deploy.yml`
ships **tvOS only** — until October 2026 it also ran the iOS lane, so every tvOS
tag uploaded a second iOS build made with the tvOS job's older Xcode.

### Toolchains — CI builds with what ships

| Platform | Runner | Xcode | CI job (required?) | Deploy |
|----------|--------|-------|--------------------|--------|
| tvOS | `macos-15` | `latest-stable` (26.x) | Build tvOS App (required) | `deploy.yml` |
| iOS | `xcode-27` | `latest-stable` (newest GA 27.x) | Build iOS App | `deploy-ios.yml` |
| Mac | `xcode-27` | `latest-stable` | Build Mac Catalyst App | `deploy-mac.yml` |
| (next Xcode) | `xcode-27` | `latest` (beta) | Forward compat — non-blocking | — |

Nothing that ships uses bare `latest`: it selects Xcode betas, and App Store
Connect rejects their uploads ("Unsupported SDK or Xcode version"). tvOS stays on
Xcode 26 because Apple rejected a tvOS upload built with Xcode 27.0 on 2026-09-17.
`scripts/check-toolchains.rb` (CI job *Release tooling*) fails if a CI job and its
deploy drift apart — change both together.

---

## Mac (Mac Catalyst)

The Mac app is the iOS target (`SashimiMobile`) built for Mac Catalyst, under the
same bundle id, so it is the **macOS platform of the same App Store Connect app**.

**Signing is Apple cloud-managed, not match.** The `mac` lanes in the Fastfile run
`xcodebuild archive` and `-exportArchive` with `-allowProvisioningUpdates` and the
App Store Connect API key (`-authenticationKeyPath/-ID/-IssuerID`), automatic
signing and ExportOptions `{method: app-store-connect, signingStyle: automatic,
manageAppVersionAndBuildNumber: false}`. Xcode creates/downloads the Catalyst
profile and Apple signs the app and the installer `.pkg` with cloud-managed
distribution certificates. The `.pkg` is uploaded with `upload_to_testflight`
(platform `osx`). It uses the same three `APP_STORE_CONNECT_*` secrets as iOS;
none of the `MATCH_*` secrets.

- The API key must have the **Admin** role (cloud-managed distribution
  certificates require it).
- A fresh runner has no signing identity, so automatic signing may create an
  Apple Development certificate to sign the archive. The workflow's last step
  (`fastlane mac revoke_runner_certificates`) revokes exactly the certificates
  whose private key is in that runner's keychain, so they don't pile up against
  the account limit.

One-time account setup (already done for 1.6.40):

1. **Developer portal → Identifiers → `com.mondominator.sashimi`**: Mac Catalyst
   enabled (no separate Mac bundle id — the project sets
   `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO`).
2. **App Store Connect → Sashimi → "+" → macOS** platform. Without it the upload
   fails with *"Cannot determine the Apple ID from Bundle ID … platform MAC_OS"*.
3. **TestFlight → macOS**: internal testers group added to macOS builds.

---

## Bumping the version — required every build

`MARKETING_VERSION` lives in **`project.yml` in three places** (tvOS, iOS, shared).
`xcodegen` writes it into the `.pbxproj`, so **editing the pbxproj directly does
nothing** — it gets regenerated.

The Release workflow does this for you. By hand:

```bash
./scripts/bump-version.sh patch    # or minor / major / 1.6.41
```

The script rewrites all three occurrences and regenerates the project. Verify:

```bash
grep -c "MARKETING_VERSION: X.Y.Z" project.yml      # expect 3
grep -o "MARKETING_VERSION = [0-9.]*;" Sashimi.xcodeproj/project.pbxproj | sort -u
```

**Why it must be bumped by hand:** fastlane only increments the *build* number.
Ship two builds under one marketing version and they are indistinguishable in
TestFlight and in Jellyfin's `ApplicationVersion`. During a 2026-08-03 playback
investigation three separate builds all reported `1.2.0`, so nobody could tell
which code was running while a fix was being tested live.

### Build numbers are epoch seconds

All three beta lanes (tvOS, iOS, Mac) call `increment_build_number(build_number: Time.now.to_i.to_s)`
(the Mac lane also passes it to `xcodebuild` as `CURRENT_PROJECT_VERSION`).
So the build number shown in TestFlight (e.g. `1789578839`) is a Unix timestamp,
not a sequential counter, and **not** the `CURRENT_PROJECT_VERSION` in
`project.yml`. That is intentional: always unique, always increasing, no
dependency on git history or an App Store Connect query.

Don't be surprised when the number you set locally isn't the number that ships.

---

## Deploying without a tag / dry runs

Each deploy workflow accepts a manual trigger with a `dry_run` box (build and sign,
no upload):

```bash
gh workflow run deploy.yml     --ref main -f environment=testflight
gh workflow run deploy-ios.yml --ref main -f environment=testflight
gh workflow run deploy-mac.yml --ref main -f environment=testflight -f dry_run=true
```

`deploy.yml` also accepts `environment=appstore` (tvOS App Store submission). Run
from a tag (`--ref ios-v1.6.41-beta1`) and the version check applies; from a branch
it only reports the version.

---

## TestFlight notes ("What to Test")

Short on purpose. `scripts/release_notes.rb` (unit-tested in
`scripts/test/release_notes_test.rb`, run by CI's *Release tooling* job):

- the Release workflow's `notes` input, if given, verbatim for every platform;
- otherwise the commits since the **previous tag of the same platform**
  (`v[0-9]*`, `ios-v[0-9]*`, `mac-v[0-9]*`; `-beta2`/`-rc` re-releases count),
  keeping only `feat`/`fix` subjects, dropping ones scoped to another platform
  (`fix(tvOS):` is not in the iOS notes), stripping prefixes, scopes, `(#123)`
  and trailing version stamps, sentence-cased, de-duplicated, at most six bullets
  plus "And N smaller fixes", under a "What to test:" line and TestFlight's 4000
  characters.

Preview locally: `ruby scripts/release_notes.rb ios` (or `tvos ios-v1.6.36-beta1 main`).

The old lanes used `changelog_from_git_commits(tag_match_pattern: "v*-beta.*")`;
our tags have no dot after `beta`, so it never found a previous tag and pasted the
whole history.

---

## After the run goes green

Uploading is not the same as being available. Confirm the upload actually
happened rather than trusting the checkmark:

```bash
gh run view <run-id> --log | grep -E "Successfully uploaded|finished processing"
```

You want `Successfully uploaded the new binary to App Store Connect`.

Apple-side processing then takes anywhere from a few minutes to ~30 before the
build is visible to testers.

> **Note on the tvOS run:** fastlane logs `Platform 'tvos' is not officially
> supported` and labels the upload `platform: IOS`. This is cosmetic — fastlane's
> vocabulary, not what was built. The archive is tvOS. Don't chase it.

---

## Secrets

Seven repository secrets drive the release and deploy workflows. **Names only — never commit
values, and never paste them into an issue, PR, or doc:**

| Secret | Purpose |
|--------|---------|
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key identifier |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect issuer identifier |
| `APP_STORE_CONNECT_KEY_CONTENT` | base64 of the `.p8` private key |
| `MATCH_PASSWORD` | Passphrase for the match certificate repo (tvOS/iOS only) |
| `MATCH_GIT_URL` | Certificate repo URL |
| `MATCH_GIT_BASIC_AUTHORIZATION` | base64 credentials for cloning that repo |
| `RELEASE_TOKEN` | Fine-grained PAT (Contents + Pull requests RW) the Release workflow opens the bump PR with — see above |

tvOS/iOS signing certificates and profiles live in a **private** match repository
(the Mac uses Apple cloud-managed signing instead). If you
need access, ask a maintainer — do not generate new certificates, as that can
invalidate the existing ones for everyone.

---

## Troubleshooting

**CI went green but no TestFlight build.** You almost certainly pushed a plain `v*`
tag by hand, which ships nothing. Use the Release workflow.

**Only one platform got a build.** Hand-pushed tags ship one platform each. Push the
others, or re-run Release with `version` = the current version, the next `beta`,
and only the missing platforms.

**"Version/tag mismatch".** The tag's version isn't `project.yml`'s
`MARKETING_VERSION`. The tag is on the wrong commit or the bump didn't merge.

**Release stuck on "Bump, PR, wait for merge".** The bump PR's CI failed or the
merge queue rejected it. Fix it; once it merges, re-run Release with the same
version — it sees `main` already at that version and skips the bump.

**"bundle version must be higher than N".** Something reset the build number —
historically caused by a stray `xcodegen generate` running *after*
`increment_build_number`, which resets `CFBundleVersion` to xcodegen's default of
1. The CI workflow generates the project *before* fastlane runs; do not add a
regeneration step inside a fastlane lane.

**"Cannot determine the Apple ID from Bundle ID … platform IOS".** App Store
Connect does not auto-add a new platform to an existing app record. A maintainer
must add the platform in App Store Connect first, then re-run the deploy.

**codesign hangs forever in CI.** The `certificates` lane must call `setup_ci`, or
codesign blocks waiting on a keychain prompt that will never be answered.

---

## Release checklist

- [ ] Actions → **Release** → Run workflow on `main` (version, beta, platforms, notes)
- [ ] Bump PR merged (link in the run summary), tags created
- [ ] The run's **tvOS / iOS / macOS** deploy jobs green
- [ ] Logs show `Successfully uploaded the new binary` for each
- [ ] Builds visible in TestFlight after Apple processing
