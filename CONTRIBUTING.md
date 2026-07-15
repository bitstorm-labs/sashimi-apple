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

While we don't have tests yet (see [issue #4](https://github.com/bitstorm-labs/sashimi-apple/issues/4)), please:
- Test your changes on tvOS Simulator
- Test on a physical Apple TV if possible
- Verify existing functionality still works

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
- Located in `Models/JellyfinModels.swift`

## Security

If you discover a security vulnerability, please:
1. **Do not** open a public issue
2. Email the maintainers directly
3. Provide details about the vulnerability
4. Allow time for a fix before public disclosure

## Questions?

Open a GitHub issue for questions or discussions about contributing.
