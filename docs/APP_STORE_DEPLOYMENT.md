# App Store Deployment Guide

This is a complete step-by-step guide for deploying Sashimi to the tvOS App Store. If you've never deployed an app before, follow this guide from the beginning.

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Apple Developer Account Setup](#2-apple-developer-account-setup)
3. [App Store Connect Setup](#3-app-store-connect-setup)
4. [Code Signing Setup](#4-code-signing-setup)
5. [CI/CD Secrets Setup](#5-cicd-secrets-setup)
6. [Local Development Deployment](#6-local-development-deployment)
7. [CI/CD Automated Deployment](#7-cicd-automated-deployment)
8. [App Store Submission](#8-app-store-submission)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Prerequisites

Before you begin, make sure you have:

- [ ] Mac with Xcode 15.0+ installed
- [ ] Apple ID
- [ ] $99 USD for Apple Developer Program enrollment
- [ ] Credit card for Apple Developer enrollment
- [ ] The Sashimi project cloned locally

### Install Required Tools

```bash
# Install Homebrew (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install XcodeGen
brew install xcodegen

# Install Ruby (if needed)
brew install ruby

# Install Fastlane
gem install fastlane

# Or install via Bundler (recommended)
cd /path/to/sashimi
bundle install
```

---

## 2. Apple Developer Account Setup

### Step 2.1: Enroll in Apple Developer Program

1. Go to [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll/)
2. Click "Start Your Enrollment"
3. Sign in with your Apple ID
4. Choose enrollment type:
   - **Individual** - For personal projects
   - **Organization** - For companies (requires D-U-N-S number)
5. Pay the $99 USD annual fee
6. Wait for approval (usually 24-48 hours)

### Step 2.2: Accept Agreements

1. Go to [developer.apple.com/account](https://developer.apple.com/account/)
2. Accept any pending agreements (required before you can submit apps)

---

## 3. App Store Connect Setup

### Step 3.1: Create App Record

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
2. Sign in with your Apple ID
3. Click **My Apps** → **+** → **New App**
4. Fill in the form:

| Field | Value |
|-------|-------|
| Platform | tvOS |
| Name | Sashimi |
| Primary Language | English (U.S.) |
| Bundle ID | com.sashimi.app |
| SKU | sashimi-tvos-001 |

5. Click **Create**

### Step 3.2: Fill in App Information

Navigate to **App Store** tab and fill in:

#### General Information
- **Subtitle**: Jellyfin Client for Apple TV
- **Category**: Entertainment
- **Content Rights**: "This app does not contain, show, or access third-party content"

#### App Privacy
1. Click **App Privacy** → **Get Started**
2. For data collection, select: **Data Not Collected**
   - Sashimi only communicates with user's own server
3. Link to privacy policy: `https://github.com/bitstorm-labs/sashimi-apple/blob/main/PRIVACY.md`

#### Age Rating
1. Click **Age Rating** → **Edit**
2. Answer the questionnaire:
   - Most answers will be "No" or "None"
   - This should result in a **4+** rating

### Step 3.3: App Review Information

In the **App Review** section:

1. **Contact Information**: Your name, email, phone
2. **Demo Account**: (Important!)
   - Reviewers need to test the app
   - Provide a working Jellyfin server URL, username, and password
   - Or explain that users must have their own server

3. **Notes**:
   ```
   Sashimi is a client for Jellyfin media servers. Users must have
   access to their own Jellyfin server to use this app.

   For testing, we can provide a demo server or you may use:
   [Your test server details]
   ```

---

## 4. Code Signing Setup

### Step 4.1: Create App IDs

1. Go to [developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers/list)
2. Click **+** to create a new identifier
3. Select **App IDs** → **Continue**
4. Select **App** → **Continue**
5. Fill in:
   - Description: `Sashimi`
   - Bundle ID: Select **Explicit** and enter `com.sashimi.app`
6. Enable capabilities:
   - **App Groups** (for TopShelf extension)
7. Click **Continue** → **Register**

8. **Repeat for TopShelf extension:**
   - Description: `Sashimi TopShelf`
   - Bundle ID: `com.sashimi.app.topshelf`
   - Enable **App Groups**

### Step 4.2: Create App Group

1. Go to **Identifiers** → **App Groups**
2. Click **+**
3. Description: `Sashimi App Group`
4. Identifier: `group.com.sashimi.app`
5. Click **Continue** → **Register**

### Step 4.3: Create Provisioning Profiles

#### Distribution Profile for Main App

1. Go to [developer.apple.com/account/resources/profiles](https://developer.apple.com/account/resources/profiles/list)
2. Click **+**
3. Select **tvOS App Store** → **Continue**
4. Select App ID: `com.sashimi.app` → **Continue**
5. Select your Distribution Certificate → **Continue**
6. Name: `Sashimi tvOS Distribution`
7. Click **Generate** → **Download**

#### Distribution Profile for TopShelf

1. Repeat steps above
2. Select App ID: `com.sashimi.app.topshelf`
3. Name: `Sashimi TopShelf Distribution`

### Step 4.4: Install Profiles in Xcode

1. Double-click downloaded `.mobileprovision` files
2. Or: Xcode → Settings → Accounts → Download Manual Profiles

---

## 5. CI/CD Secrets Setup

For automated deployment via GitHub Actions, you need to set up secrets.

### Step 5.1: Create App Store Connect API Key

1. Go to [appstoreconnect.apple.com/access/api](https://appstoreconnect.apple.com/access/api)
2. Click **Keys** tab → **+** (Generate API Key)
3. Name: `Sashimi CI`
4. Access: **App Manager**
5. Click **Generate**
6. **Download the .p8 file immediately** (you can only download it once!)
7. Note the **Key ID** and **Issuer ID** shown on the page

### Step 5.2: Set Up Match (Certificate Storage)

Match stores your certificates in a private Git repository. This is the recommended approach.

1. Create a **private** GitHub repository for certificates:
   - Example: `github.com/bitstorm-labs/certificates` (private!)

2. Initialize Match:
   ```bash
   cd /path/to/sashimi
   bundle exec fastlane match init
   ```
   - Select **git**
   - Enter your certificates repo URL

3. Generate certificates:
   ```bash
   bundle exec fastlane match appstore
   ```
   - This creates distribution certificates and profiles
   - You'll be prompted for a password - **save this password!**

### Step 5.3: Add GitHub Secrets

Go to your repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Add these secrets:

| Secret Name | Value |
|-------------|-------|
| `APP_STORE_CONNECT_KEY_ID` | Your API Key ID (from Step 5.1) |
| `APP_STORE_CONNECT_ISSUER_ID` | Your Issuer ID (from Step 5.1) |
| `APP_STORE_CONNECT_KEY_CONTENT` | Base64-encoded .p8 file content* |
| `MATCH_PASSWORD` | Password you set for Match |
| `MATCH_GIT_URL` | `git@github.com:bitstorm-labs/certificates.git` |

*To base64 encode the .p8 file:
```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

### Step 5.4: Add Deploy Key for Match Repo

1. Generate SSH key:
   ```bash
   ssh-keygen -t ed25519 -C "github-actions" -f deploy_key
   ```

2. Add **public key** as Deploy Key to certificates repo:
   - Go to certificates repo → Settings → Deploy Keys → Add
   - Paste contents of `deploy_key.pub`
   - Enable **Allow write access**

3. Add **private key** as secret to Sashimi repo:
   - Secret name: `MATCH_DEPLOY_KEY`
   - Value: Contents of `deploy_key`

---

## 6. Local Development Deployment

### Deploy to TestFlight Manually

```bash
cd /path/to/sashimi

# Install dependencies
bundle install

# Generate Xcode project
xcodegen generate

# Deploy to TestFlight
bundle exec fastlane beta
```

### Deploy to App Store Manually

```bash
bundle exec fastlane release
```

---

## 7. CI/CD Automated Deployment

### TestFlight (Beta) Deployment

Automatic on beta tags:
```bash
# Bump version and create beta tag
./scripts/bump-version.sh patch
git add -A && git commit -m "chore: bump version"
git tag v1.0.1-beta.1
git push && git push --tags
```

### Manual Deployment via GitHub Actions

1. Go to **Actions** tab in GitHub
2. Select **Deploy** workflow
3. Click **Run workflow**
4. Choose environment: `testflight` or `appstore`
5. Click **Run workflow**

---

## 8. App Store Submission

### Step 8.1: Upload Build

After running `fastlane release` or the CI workflow, your build uploads to App Store Connect.

### Step 8.2: Add Screenshots

1. In App Store Connect, go to your app → **App Store** tab
2. Scroll to **tvOS Screenshots**
3. Upload screenshots:
   - **Apple TV**: 1920×1080 or 3840×2160
4. Add at least 1 screenshot

### Step 8.3: Submit for Review

1. Fill in all required metadata
2. Select your uploaded build
3. Click **Submit for Review**

### What to Expect

- **Review time**: Usually 24-48 hours, sometimes up to a week
- **Rejection reasons**: Often minor issues, fixable
- **Common rejections**:
  - Missing demo account
  - Bugs found during review
  - Guideline violations

---

## 9. Troubleshooting

### "No matching provisioning profiles found"

```bash
# Regenerate profiles
bundle exec fastlane match appstore --force
```

### "The bundle identifier does not match"

- Ensure Bundle ID in App Store Connect matches `com.sashimi.app`
- Check `project.yml` has correct `PRODUCT_BUNDLE_IDENTIFIER`

### "Invalid binary"

- Make sure you're building for tvOS, not iOS
- Check deployment target is tvOS 17.0+

### CI Workflow Fails

1. Check **Actions** logs for specific error
2. Verify all secrets are set correctly
3. Ensure certificates haven't expired

### Match Password Lost

If you lose the Match password:
1. Delete all certs from certificates repo
2. Revoke certificates in Apple Developer Portal
3. Run `bundle exec fastlane match appstore` again with new password

---

## Quick Reference

### Version Bump Commands

```bash
./scripts/bump-version.sh patch  # 1.0.0 → 1.0.1
./scripts/bump-version.sh minor  # 1.0.0 → 1.1.0
./scripts/bump-version.sh major  # 1.0.0 → 2.0.0
```

### Fastlane Commands

```bash
bundle exec fastlane beta      # Deploy to TestFlight
bundle exec fastlane release   # Deploy to App Store
bundle exec fastlane certificates  # Sync certificates
```

### Git Tags

```bash
git tag v1.0.0              # Release version
git tag v1.0.1-beta.1       # Beta version (auto-deploys)
git tag v1.0.1-rc.1         # Release candidate
```

---

## Support

If you run into issues:
1. Check [Fastlane docs](https://docs.fastlane.tools/)
2. Check [Apple Developer docs](https://developer.apple.com/documentation/)
3. Open an issue on GitHub
