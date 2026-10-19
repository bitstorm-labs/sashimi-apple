# App Store setup (one time)

> **Shipping a release? See [RELEASING.md](RELEASING.md).**
>
> This page covers one-time setup: the Apple Developer account, App Store Connect
> records, signing and CI secrets. Anyone forking the project to publish their own
> build needs it. Day-to-day releases don't.

Sashimi is one App Store Connect app with three platforms: tvOS, iOS (iPhone and
iPad) and macOS (Mac Catalyst). They share the bundle id
`com.mondominator.sashimi` (Universal Purchase). Replace the bundle ids, team id
and repository names below with your own if you fork it.

## 1. Tools

```bash
brew install xcodegen
bundle install            # fastlane, from the Gemfile
```

You need Xcode 26 or newer. See the toolchain table in [RELEASING.md](RELEASING.md)
for which Xcode each platform ships with.

## 2. Apple Developer account

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/enroll/)
   and accept any pending agreements at developer.apple.com/account.
2. **Identifiers**: register two explicit App IDs with the **App Groups**
   capability.
   - `com.mondominator.sashimi` (also enable **Mac Catalyst**)
   - `com.mondominator.sashimi.topshelf` (the Top Shelf extension)
3. **App Groups**: register `group.com.mondominator.sashimi` and attach it to both
   App IDs.

## 3. App Store Connect

1. **My Apps → + → New App**. Pick tvOS first, bundle id
   `com.mondominator.sashimi`. Then open the app and add **iOS** and **macOS**
   from the "+" next to the platform list. App Store Connect doesn't add a
   platform on upload. Without it, uploads fail with *"Cannot determine the Apple
   ID from Bundle ID … platform …"*.
2. **App Privacy**: Data Not Collected. Privacy policy URL:
   `https://github.com/bitstorm-labs/sashimi-apple/blob/main/PRIVACY.md`.
3. **Age rating**: answer the questionnaire; it comes out at 4+.
4. **App Review information**: reviewers need a Jellyfin server. Give them a demo
   server URL and account, or explain that users bring their own server.
5. **TestFlight**: add an internal testers group for each platform.

Store text and keywords live in `fastlane/metadata/en-US/`.

## 4. API key and signing

1. **Users and Access → Integrations → App Store Connect API**: generate a key
   with the **Admin** role (the Mac lane's cloud-managed signing needs it). Download
   the `.p8` once. Note the Key ID and Issuer ID.
2. **tvOS and iOS** sign with fastlane `match`, with certificates in a **private**
   Git repository (see `fastlane/Matchfile`):
   ```bash
   bundle exec fastlane tvos certificates
   bundle exec fastlane ios certificates
   ```
   Pick a passphrase when asked and keep it.
3. **Mac** uses Apple's cloud-managed signing, so there is nothing to set up
   beyond the Admin API key. Details are in [RELEASING.md](RELEASING.md#mac-mac-catalyst).

## 5. GitHub secrets

Repository → **Settings → Secrets and variables → Actions**. The full list, with
what each is for, is in [RELEASING.md](RELEASING.md#secrets). The base64 value of
the key file:

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

`RELEASE_TOKEN` (a fine-grained token that lets the Release workflow open its
version-bump PR) is set up as described in RELEASING.md.

## 6. First build

Run the Release workflow with `dry_run=true` from any branch. It builds and signs
each platform and uploads nothing:

```bash
gh workflow run release.yml --ref <branch> -f dry_run=true
```

Then run it for real (see [RELEASING.md](RELEASING.md)). After the first
TestFlight build processes, add screenshots and metadata in App Store Connect and
submit the build for review. The tvOS App Store lane is
`gh workflow run deploy.yml -f environment=appstore`.

Review usually takes one to two days. Common rejections: no demo account,
bugs found during review.

## Troubleshooting

**"No matching provisioning profiles found"**: regenerate with
`bundle exec fastlane tvos certificates` (or `ios certificates`) and check the
certificates haven't expired.

**"The bundle identifier does not match"**: the App Store Connect bundle id must
equal `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.

**Lost the match passphrase**: delete the certificates in the match repository,
revoke them in the developer portal, and run the `certificates` lanes again with a
new passphrase.

For anything about a release run failing, see the troubleshooting section of
[RELEASING.md](RELEASING.md).
