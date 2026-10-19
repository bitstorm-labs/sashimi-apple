# Contributing to Sashimi

Thank you for your interest in contributing to Sashimi! This document provides guidelines and instructions for contributing.

## Code of Conduct

Please be respectful and constructive in all interactions. We welcome contributors of all experience levels.

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Run `./scripts/setup.sh` to configure your development environment
4. Create a feature branch from `main`

## Development Workflow

### Branch Naming

Use descriptive branch names with prefixes:

- `feat/` - New features
- `fix/` - Bug fixes
- `docs/` - Documentation updates
- `refactor/` - Code refactoring
- `test/` - Test additions/updates

Example: `feat/picture-in-picture-support`

### Commit Messages

We use [Conventional Commits](https://www.conventionalcommits.org/). The git hooks will validate your commit messages.

Format: `type(scope): description`

Types:
- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation
- `style` - Formatting, no code change
- `refactor` - Code change that neither fixes a bug nor adds a feature
- `perf` - Performance improvement
- `test` - Adding tests
- `build` - Build system changes
- `ci` - CI configuration
- `chore` - Other changes

Examples:
```
feat(player): add picture-in-picture support
fix(auth): resolve token refresh race condition
docs: update installation instructions
```

### Code Style

- Follow existing code patterns in the project
- Use SwiftLint (configured in `.swiftlint.yml`)
- Prefer `@MainActor` for UI-related code
- Use `actor` for thread-safe service classes
- Follow MVVM architecture

### Pull Requests

1. Ensure your code builds without warnings
2. Run SwiftLint and fix any issues
3. Update documentation if needed
4. Write a clear PR description explaining:
   - What changes were made
   - Why they were made
   - Any testing performed

### Testing

Unit tests live in `SashimiTests/` (tvOS host) and `SashimiMobileTests/` (iOS).
Add or update a test for the behavior you change. CI builds and tests each
platform. Please also:
- Run the app on the simulator for the platform you changed (tvOS, iPhone or iPad)
- Say in the PR what you checked on a real device, and what you could not
- Check that changes in `Shared/` still work on both tvOS and iOS

## Architecture Guidelines

### Services
- API calls go through `JellyfinClient` (actor-based singleton)
- Session state managed by `SessionManager`
- Sensitive data stored via `KeychainHelper`

### ViewModels
- Marked with `@MainActor`
- Conform to `ObservableObject`
- Handle business logic and API calls
- Expose `@Published` properties for view binding

### Views
- Pure SwiftUI
- Create `@StateObject` ViewModels internally
- Use `@EnvironmentObject` for `SessionManager`

### Models
- `Codable` structs matching Jellyfin API
- Located in `Shared/Models/`

## Releasing

Maintainers only. You don't need to do anything: when a PR that changes app
code merges to `main`, an automatic workflow ships a TestFlight build for tvOS,
iOS and Mac. Don't bump `MARKETING_VERSION` in your PR or push release tags. See
**[docs/RELEASING.md](docs/RELEASING.md)** for the runbook.

## Security

If you discover a security vulnerability, please:
1. **Do not** open a public issue
2. Report it privately through the repository's GitHub Security tab (Report a vulnerability)
3. Provide details about the vulnerability
4. Allow time for a fix before public disclosure

## Questions?

Open a GitHub issue for questions or discussions about contributing.
