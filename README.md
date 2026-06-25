# Sashimi

<p align="center">
  <img src="sashimi-logo.png" alt="Sashimi Logo" width="200">
</p>

<p align="center">
  <strong>A native Jellyfin client for Apple TV, iPhone, and iPad</strong>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#requirements">Requirements</a> •
  <a href="#installation">Installation</a> •
  <a href="#development">Development</a> •
  <a href="#contributing">Contributing</a>
</p>

---

Sashimi is a SwiftUI Jellyfin client that ships as a single universal app across
Apple TV, iPhone, and iPad (Universal Purchase). The Apple TV and mobile apps
share their networking, authentication, and playback logic.

## Features

**All platforms**
- Native SwiftUI interface tailored per device (Apple TV, iPhone tabs, iPad sidebar)
- Browse and stream your Jellyfin media library
- Support for movies, TV shows, and YouTube-style content
- Continue watching with playback progress sync
- Audio/subtitle track selection, quality switching, and skip intro/credits
- Secure credential storage using Keychain

**Apple TV**
- Top Shelf integration for quick access to recent content

**iPhone & iPad**
- Offline mode: download media and watch without a connection
- Picture-in-Picture playback
- Adaptive layouts for phone (tabs) and tablet (sidebar)

## Requirements

- tvOS 17.0+ / iOS 17.0+
- Jellyfin server (local or remote)
- Xcode 16.0+ for development (Xcode 26+ required for TestFlight/App Store builds —
  Apple mandates building with the current SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the Xcode project is generated
  from `project.yml`)

## Installation

### From Source

1. Clone the repository:
   ```bash
   git clone https://github.com/mondominator/sashimi.git
   cd sashimi
   ```

2. Run the setup script (installs hooks, generates the project):
   ```bash
   ./scripts/setup.sh
   ```

3. Open `Sashimi.xcodeproj` in Xcode

4. Select your development team in Signing & Capabilities

5. Choose a scheme and run:
   - **Sashimi** → Apple TV (tvOS)
   - **SashimiMobile** → iPhone / iPad (iOS)

### Dependencies

- [Nuke](https://github.com/kean/Nuke) - Image loading and caching

## Development

### Project Structure

```
sashimi/
├── Sashimi/          # tvOS app (SwiftUI)
├── SashimiMobile/    # iPhone + iPad app (SwiftUI)
│   ├── Views/        # Phone/iPad layouts, player, downloads
│   └── Downloads/    # Background downloads & offline storage
├── TopShelf/         # tvOS Top Shelf extension
├── Shared/           # Code shared by tvOS + iOS
│   ├── Services/     # JellyfinClient, SessionManager, server discovery
│   ├── ViewModels/   # Player and home view models
│   └── Models/       # Jellyfin API data models
└── SashimiTests/     # Unit tests
```

### Build Commands

```bash
# Generate the Xcode project (requires XcodeGen)
xcodegen generate

# Build the tvOS app
xcodebuild -project Sashimi.xcodeproj -scheme Sashimi \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'

# Build the iOS app (iPhone/iPad)
xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Distribution

Both apps ship to TestFlight via fastlane + GitHub Actions:

- tvOS: push a tag matching `v*-beta*` (e.g. `v1.0.0-beta.1`)
- iOS: push a tag matching `ios-v*-beta*` (e.g. `ios-v1.0.1-beta.1`)

Code signing uses fastlane `match`. The version comes from `MARKETING_VERSION` in
`project.yml`; the build number is set automatically at build time.

### Git Hooks

This project uses git hooks for code quality. After cloning, run:

```bash
git config core.hooksPath .githooks
```

Or use the setup script which configures this automatically.

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Commit using conventional commits: `git commit -m "feat: add new feature"`
4. Push to your fork: `git push origin feat/my-feature`
5. Open a Pull Request

### Commit Message Format

This project uses [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `style:` - Code style changes
- `refactor:` - Code refactoring
- `test:` - Test updates
- `chore:` - Maintenance tasks

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Jellyfin](https://jellyfin.org/) - The free software media system
- [Nuke](https://github.com/kean/Nuke) - Image loading framework
