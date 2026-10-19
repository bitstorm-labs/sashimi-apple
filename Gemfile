source "https://rubygems.org"

gem "fastlane", "~> 2.241"

# A literal path: Dependabot's bundler updater refuses to parse an
# eval_gemfile with an interpolated argument (fastlane's generated
# `eval_gemfile(plugins_path) if File.exist?(plugins_path)` form), and
# fastlane only checks that the Gemfile mentions "Pluginfile". Bundler
# resolves the path relative to this Gemfile.
eval_gemfile "fastlane/Pluginfile"
