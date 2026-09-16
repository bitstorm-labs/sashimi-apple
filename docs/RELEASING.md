# Releasing Sashimi

How a build actually reaches TestFlight. Read this before shipping — there is one
trap here that produces a **green CI run that ships nothing**, and it has bitten
this project in production.

For one-time account, certificate and App Store Connect setup, see
[APP_STORE_DEPLOYMENT.md](APP_STORE_DEPLOYMENT.md). This document covers only the
recurring release flow.

---

## The short version

```bash
./scripts/bump-version.sh patch          # 1. bump MARKETING_VERSION
git commit -am "chore: bump version to X.Y.Z"
# 2. open a PR, merge on green CI

git tag -a vX.Y.Z-beta1     -m "Sashimi X.Y.Z-beta1 (tvOS)"
git tag -a ios-vX.Y.Z-beta1 -m "Sashimi X.Y.Z-beta1 (iOS/iPad)"
git push origin vX.Y.Z-beta1 ios-vX.Y.Z-beta1    # 3. push BOTH tags

gh run list --limit 5        # 4. confirm "Deploy" AND "Deploy iOS" both started
```

Step 4 is not optional. See below.

---

## ⚠️ A plain `vX.Y.Z` tag does NOT ship to TestFlight

This is the one thing to remember.

| Tag | Workflow | What happens |
|-----|----------|--------------|
| `v1.4.1-beta1` / `v1.4.1-rc1` | `deploy.yml` | **tvOS → TestFlight** |
| `ios-v1.4.1-beta1` / `ios-v1.4.1-rc1` | `deploy-ios.yml` | **iOS/iPad → TestFlight** |
| `v1.4.1` (plain) | `release.yml` | Builds an archive artifact. **Ships nothing.** |

`release.yml` triggers on `v*` but explicitly *excludes* `-beta` and `-rc`, and it
only runs `actions/upload-artifact`. There is no upload step in it at all.

**Why this matters:** on 2026-08-10, v1.2.14 was shipped with a plain `v1.2.14`
tag. CI went green. No TestFlight build ever appeared, and the first signal was a
human noticing the build was missing. The fix was pushing `v1.2.14-beta1` and
`ios-v1.2.14-beta1`.

A green checkmark tells you *a* workflow succeeded. It does not tell you the
**deploy** workflow ran. Always confirm the workflow *name*:

```bash
gh run list --limit 5 --json workflowName,headBranch,status \
  --jq '.[] | "\(.workflowName) [\(.headBranch)] \(.status)"'
```

You want to see both `Deploy` and `Deploy iOS`. If you only see `Release`, you
used the wrong tag and nothing is shipping.

---

## tvOS and iOS are two separate pipelines

They are one app (Universal Purchase, shared bundle id `com.mondominator.sashimi`,
distinguished by platform) but **two workflows and two tag namespaces**.

Pushing only `vX.Y.Z-beta1` ships tvOS and silently does nothing for iOS. There is
no warning — the tvOS run goes green and looks like a complete release.

**Always push both tags.**

---

## Bumping the version — required every build

`MARKETING_VERSION` lives in **`project.yml` in three places** (tvOS, iOS, shared).
`xcodegen` writes it into the `.pbxproj`, so **editing the pbxproj directly does
nothing** — it gets regenerated.

```bash
./scripts/bump-version.sh patch    # or minor / major
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

Both beta lanes call `increment_build_number(build_number: Time.now.to_i.to_s)`.
So the build number shown in TestFlight (e.g. `1789578839`) is a Unix timestamp,
not a sequential counter, and **not** the `CURRENT_PROJECT_VERSION` in
`project.yml`. That is intentional: always unique, always increasing, no
dependency on git history or an App Store Connect query.

Don't be surprised when the number you set locally isn't the number that ships.

---

## Deploying without a tag

Both workflows accept a manual trigger:

```bash
gh workflow run deploy.yml     --ref main -f environment=testflight
gh workflow run deploy-ios.yml --ref main -f environment=testflight
```

`environment` accepts `testflight` or `appstore`. Or use the **Actions** tab →
**Deploy** / **Deploy iOS** → **Run workflow**.

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

Six repository secrets drive the deploy workflows. **Names only — never commit
values, and never paste them into an issue, PR, or doc:**

| Secret | Purpose |
|--------|---------|
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key identifier |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect issuer identifier |
| `APP_STORE_CONNECT_KEY_CONTENT` | base64 of the `.p8` private key |
| `MATCH_PASSWORD` | Passphrase for the match certificate repo |
| `MATCH_GIT_URL` | Certificate repo URL |
| `MATCH_GIT_BASIC_AUTHORIZATION` | base64 credentials for cloning that repo |

Signing certificates and profiles live in a **private** match repository. If you
need access, ask a maintainer — do not generate new certificates, as that can
invalidate the existing ones for everyone.

---

## Troubleshooting

**CI went green but no TestFlight build.** You almost certainly used a plain `v*`
tag. Check `gh run list` for the workflow name. Push `vX.Y.Z-beta1` and
`ios-vX.Y.Z-beta1`.

**Only one platform got a build.** You pushed only one tag. Push the other.

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

- [ ] `./scripts/bump-version.sh <patch|minor|major>` — all three spots updated
- [ ] Version change merged to `main` with CI green
- [ ] Both tags created: `vX.Y.Z-beta1` **and** `ios-vX.Y.Z-beta1`
- [ ] Both tags pushed
- [ ] `gh run list` shows **`Deploy`** and **`Deploy iOS`** (not `Release`)
- [ ] Both runs green
- [ ] Logs show `Successfully uploaded the new binary` for each
- [ ] Builds visible in TestFlight after Apple processing
