# frozen_string_literal: true

# TestFlight "What to Test" notes, short enough for a tester to read.
#
# Used by the beta lanes in fastlane/Fastfile and runnable on its own:
#
#   ruby scripts/release_notes.rb ios                 # notes for HEAD
#   ruby scripts/release_notes.rb tvos ios-v1.6.36-beta1 v1.6.40-beta1
#
# Why this exists: the lanes used to call
# `changelog_from_git_commits(tag_match_pattern: "v*-beta.*")`. Our tags are
# `v1.6.40-beta1` (no dot after "beta"), so the only tag that pattern ever
# matched was the ancient v1.2.0-beta.4 -- every 1.6.x build pasted ~220
# commits (everything since July) into TestFlight.
#
# Rules:
#   * RELEASE_NOTES (the Release workflow's `notes` input) wins, verbatim.
#   * Otherwise: commits since the previous tag OF THE SAME PLATFORM, only
#     user-facing feat/fix subjects, prefixes/scopes/PR numbers stripped,
#     sentence-cased, de-duplicated, at most MAX_BULLETS bullets.
#   * Never longer than TestFlight's 4000-character limit.
require "open3"

module ReleaseNotes
  MAX_CHARS = 4000
  MAX_BULLETS = 6
  MAX_BULLET_CHARS = 200
  HEADER = "What to test:"
  FALLBACK = "General fixes and improvements"

  # git-describe --match globs, one per platform's tag namespace. `v[0-9]*`
  # (not `v*`) so the tvOS pattern can never pick up an ios-/mac- tag, and no
  # "beta" in the pattern so -beta2 / -rc1 re-releases are found too.
  TAG_PATTERNS = {
    tvos: "v[0-9]*",
    ios: "ios-v[0-9]*",
    mac: "mac-v[0-9]*"
  }.freeze

  # A commit scoped to one platform is noise in another platform's notes.
  PLATFORM_SCOPES = {
    tvos: %w[tvos appletv atv],
    ios: %w[ios iphone ipad mobile],
    mac: %w[mac macos catalyst]
  }.freeze

  CONVENTIONAL = /\A(?<type>[a-z]+)(?:\((?<scope>[^)]*)\))?!?:\s*(?<desc>.+)\z/i

  module_function

  # Returns the notes text for `platform` (:tvos, :ios or :mac).
  # `current_tag` is excluded from the previous-tag search, so this works
  # whether or not the release tag already points at HEAD.
  def for_platform(platform, head: "HEAD", current_tag: nil, override: ENV.fetch("RELEASE_NOTES", nil),
                   repo: Dir.pwd)
    return clamp(override.strip) if override && !override.strip.empty?

    previous = previous_tag(platform, head: head, exclude: current_tag, repo: repo)
    format_notes(subjects(previous, head, repo: repo), platform)
  end

  # The nearest tag of this platform reachable from `head`, or nil.
  def previous_tag(platform, head: "HEAD", exclude: nil, repo: Dir.pwd)
    pattern = TAG_PATTERNS.fetch(platform.to_sym)
    args = ["git", "describe", "--tags", "--abbrev=0", "--match", pattern]
    args += ["--exclude", exclude] if exclude && !exclude.empty?
    out, status = Open3.capture2e(*args, head, chdir: repo)
    status.success? ? out.strip : nil
  end

  # Commit subjects in previous..head, newest first, merges excluded. With no
  # previous tag, only the last 50 commits (never the whole history).
  def subjects(previous, head = "HEAD", repo: Dir.pwd)
    range = previous ? ["#{previous}..#{head}"] : ["-n", "50", head]
    out, status = Open3.capture2e("git", "log", "--no-merges", "--format=%s", *range, chdir: repo)
    raise "git log failed: #{out}" unless status.success?

    out.lines.map(&:strip).reject(&:empty?)
  end

  # Pure formatting: list of commit subjects -> notes text.
  def format_notes(subject_list, platform)
    bullets = []
    seen = {}
    subject_list.each do |subject|
      line = user_facing(subject, platform)
      next unless line

      key = line.downcase.gsub(/[^a-z0-9]+/, " ").strip
      next if seen[key]

      seen[key] = true
      bullets << line
    end

    shown = bullets.first(MAX_BULLETS)
    hidden = bullets.size - shown.size
    lines = shown.empty? ? [FALLBACK] : shown
    lines << "And #{hidden} smaller #{hidden == 1 ? 'fix' : 'fixes'}" if hidden.positive?
    clamp(([HEADER] + lines.map { |l| "• #{l}" }).join("\n"))
  end

  # One commit subject -> a tester-facing sentence, or nil to drop it.
  def user_facing(subject, platform)
    match = CONVENTIONAL.match(subject.strip)
    return nil unless match
    return nil unless %w[feat fix].include?(match[:type].downcase)

    scope = match[:scope].to_s.downcase.gsub(/[^a-z]/, "")
    other_platforms = PLATFORM_SCOPES.reject { |p, _| p == platform.to_sym }.values.flatten
    return nil if other_platforms.include?(scope)

    text = match[:desc]
    text = text.gsub(/\s*\(#\d+\)/, "")                 # "(#123)" PR numbers
    text = text.gsub(/[;,]?\s*\b\d+\.\d+\.\d+\b\s*\z/, "") # trailing "; 1.6.40" version stamp
    text = text.sub(/\s*(\.\.\.|…)\z/, "")              # GitHub-truncated titles
    text = text.strip.sub(/[.;,:]\z/, "")
    return nil if text.empty?
    return nil if text =~ /\A(bump|release|version)\b/i

    text = "#{text[0, MAX_BULLET_CHARS - 1].rstrip}…" if text.length > MAX_BULLET_CHARS
    sentence_case(text)
  end

  # "up next works" -> "Up next works", but "iOS", "tvOS", "iPad" stay as-is.
  def sentence_case(text)
    first_word = text[/\A\S+/].to_s
    return text if first_word =~ /\A[a-z]+[A-Z]/

    text[0].upcase + text[1..]
  end

  def clamp(text)
    return text if text.length <= MAX_CHARS

    "#{text[0, MAX_CHARS - 1]}…"
  end
end

if $PROGRAM_NAME == __FILE__
  platform = (ARGV[0] || "ios").to_sym
  abort "usage: #{$PROGRAM_NAME} tvos|ios|mac [from-tag] [to-ref]" unless ReleaseNotes::TAG_PATTERNS.key?(platform)
  if ARGV[1]
    puts ReleaseNotes.format_notes(ReleaseNotes.subjects(ARGV[1], ARGV[2] || "HEAD"), platform)
  else
    puts ReleaseNotes.for_platform(platform, current_tag: ENV.fetch("RELEASE_TAG", nil))
  end
end
