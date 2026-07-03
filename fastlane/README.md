fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## tvos

### tvos certificates

```sh
[bundle exec] fastlane tvos certificates
```

Sync certificates and profiles from App Store Connect

### tvos build

```sh
[bundle exec] fastlane tvos build
```

Build the app

### tvos beta

```sh
[bundle exec] fastlane tvos beta
```

Push a new build to TestFlight

### tvos release

```sh
[bundle exec] fastlane tvos release
```

Deploy a new version to the App Store

### tvos create_app_record

```sh
[bundle exec] fastlane tvos create_app_record
```

TEMP: create ASC app record

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
