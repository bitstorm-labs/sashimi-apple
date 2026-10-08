# frozen_string_literal: true

# ruby scripts/test/release_notes_test.rb
require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../release_notes"

class ReleaseNotesFormatTest < Minitest::Test
  def test_keeps_only_feat_and_fix_and_strips_prefix_scope_and_pr_numbers
    notes = ReleaseNotes.format_notes([
      "ci: pin third-party actions to commit SHAs (#640)",
      "fix(tvOS): hero picture inset 30pt; 1.6.40 (#639)",
      "chore: 1.6.39 (#638)",
      "fix: Auto quality follows the measured link (#631) (#632)",
      "test: cover the resume threshold",
      "docs: releasing guide",
      "refactor(player): split the view model",
      "feat: up Next countdown now plays the next episode"
    ], :tvos)

    assert_equal <<~NOTES.chomp, notes
      What to test:
      • Hero picture inset 30pt
      • Auto quality follows the measured link
      • Up Next countdown now plays the next episode
    NOTES
  end

  def test_drops_commits_scoped_to_another_platform
    subjects = ["feat(mac): Mac Catalyst app built from the iPad UI (#637)", "fix(tvOS): overscan strip"]
    assert_equal "What to test:\n• Overscan strip", ReleaseNotes.format_notes(subjects, :tvos)
    assert_equal "What to test:\n• #{ReleaseNotes::FALLBACK}", ReleaseNotes.format_notes(subjects, :ios)
    assert_includes ReleaseNotes.format_notes(subjects, :mac), "Mac Catalyst app"
    refute_includes ReleaseNotes.format_notes(subjects, :mac), "Overscan"
  end

  def test_dedupes_caps_bullets_and_counts_the_rest
    subjects = (1..9).map { |i| "fix: thing #{i}" } + ["fix: Thing 1.", "fix: thing 1 (#9)"]
    lines = ReleaseNotes.format_notes(subjects, :ios).lines.map(&:chomp)
    assert_equal "What to test:", lines.first
    assert_equal 1 + ReleaseNotes::MAX_BULLETS + 1, lines.size
    assert_equal "• And 3 smaller fixes", lines.last
  end

  def test_version_bumps_and_nothing_user_facing_fall_back
    notes = ReleaseNotes.format_notes(["chore: 1.6.41", "fix: bump version to 1.6.41"], :tvos)
    assert_equal "What to test:\n• #{ReleaseNotes::FALLBACK}", notes
  end

  def test_never_exceeds_testflight_limit
    long = (1..6).map { |i| "feat: #{'x' * 5000} #{i}" }
    assert_operator ReleaseNotes.format_notes(long, :ios).length, :<=, ReleaseNotes::MAX_CHARS
    assert_operator ReleaseNotes.for_platform(:ios, override: "y" * 9000).length, :<=, ReleaseNotes::MAX_CHARS
  end

  def test_override_is_used_verbatim
    text = "• Up Next countdown now plays the next episode\n• Home updates after watching elsewhere"
    assert_equal text, ReleaseNotes.for_platform(:tvos, override: "#{text}\n")
  end
end

# Real git repo, real tag names: this is the bug that dumped the whole
# history into TestFlight (pattern "v*-beta.*" never matched "v1.6.40-beta1").
class ReleaseNotesTagTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    git "init", "-q", "-b", "main"
    git "config", "user.email", "ci@example.com"
    git "config", "user.name", "ci"
    commit "fix: ancient history"
    tag "v1.6.35-beta1"
    tag "ios-v1.6.35-beta1"
    commit "fix: shipped in 36"
    tag "v1.6.36-beta1"
    tag "ios-v1.6.36-beta1"
    commit "fix: iOS-only rebuild fix"
    tag "ios-v1.6.36-beta2"
    commit "feat: new in 37"
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_previous_tag_is_per_platform_and_finds_re_release_tags
    assert_equal "v1.6.36-beta1", ReleaseNotes.previous_tag(:tvos, repo: @dir)
    assert_equal "ios-v1.6.36-beta2", ReleaseNotes.previous_tag(:ios, repo: @dir)
    assert_nil ReleaseNotes.previous_tag(:mac, repo: @dir)
  end

  def test_notes_cover_only_commits_since_the_platforms_previous_tag
    tvos = ReleaseNotes.for_platform(:tvos, override: nil, repo: @dir)
    ios = ReleaseNotes.for_platform(:ios, override: nil, repo: @dir)
    assert_equal "What to test:\n• New in 37\n• iOS-only rebuild fix", tvos
    assert_equal "What to test:\n• New in 37", ios
    refute_includes tvos, "Ancient history"
  end

  def test_the_old_fastlane_pattern_never_matched_our_tags
    _, status = Open3.capture2e("git", "describe", "--tags", "--abbrev=0", "--match", "v*-beta.*", chdir: @dir)
    refute status.success?, "the old pattern should find no tag -- that was the bug"
  end

  def test_current_tag_at_head_is_excluded
    tag "v1.6.37-beta1"
    notes = ReleaseNotes.for_platform(:tvos, current_tag: "v1.6.37-beta1", override: nil, repo: @dir)
    assert_includes notes, "New in 37"
  end

  def test_platform_patterns_do_not_cross_namespaces
    tag "mac-v1.6.37-beta1"
    tag "ios-v1.6.37-beta1"
    assert_equal "v1.6.36-beta1", ReleaseNotes.previous_tag(:tvos, repo: @dir)
  end

  private

  def git(*args)
    out, status = Open3.capture2e("git", *args, chdir: @dir)
    raise out unless status.success?
  end

  def commit(message)
    git "commit", "-q", "--allow-empty", "-m", message
  end

  def tag(name)
    git "tag", name
  end
end
