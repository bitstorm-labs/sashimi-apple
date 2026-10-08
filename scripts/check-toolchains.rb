# frozen_string_literal: true

# Fails if a CI build job and the deploy job for the same platform drift onto
# different runner images or Xcode selectors, or if anything that ships uses a
# bare 'latest' (which picks Xcode betas; App Store Connect rejects their
# uploads). A green PR has to prove the toolchain we actually ship with.
#
#   ruby scripts/check-toolchains.rb
require "yaml"

WORKFLOWS = File.expand_path("../.github/workflows", __dir__)

# platform => [[workflow file, job id], ...]; every entry must share one
# (runs-on, xcode-version) pair.
PAIRS = {
  "tvOS" => [["ci.yml", "build"], ["deploy.yml", "deploy"]],
  "iOS/Mac" => [["ci.yml", "build-ios"], ["ci.yml", "build-mac"],
                ["deploy-ios.yml", "deploy"], ["deploy-mac.yml", "deploy"]]
}.freeze

# The only jobs allowed to select an Xcode beta. They must not block merges.
BETA_ALLOWED = [["ci.yml", "forward-compat"]].freeze

def xcode_version(workflow, job)
  step = (job["steps"] || []).find { |s| s["uses"].to_s.start_with?("maxim-lobanov/setup-xcode@") }
  return nil unless step

  version = step.dig("with", "xcode-version").to_s
  if (m = version.match(/\A\$\{\{\s*env\.(\w+)\s*\}\}\z/))
    version = (job.dig("env", m[1]) || workflow.dig("env", m[1])).to_s
  end
  version
end

errors = []
toolchains = {}

Dir[File.join(WORKFLOWS, "*.yml")].sort.each do |path|
  file = File.basename(path)
  workflow = YAML.safe_load_file(path, aliases: true)
  (workflow["jobs"] || {}).each do |id, job|
    version = xcode_version(workflow, job)
    next unless version

    toolchains[[file, id]] = [job["runs-on"], version]
    allowed_beta = BETA_ALLOWED.include?([file, id])
    if version != "latest-stable" && !allowed_beta
      errors << "#{file} job '#{id}' selects Xcode '#{version}'; shipping/required jobs must use 'latest-stable'"
    end
    if allowed_beta && job["continue-on-error"] != true
      errors << "#{file} job '#{id}' uses an Xcode beta and must be continue-on-error: true"
    end
  end
end

PAIRS.each do |platform, jobs|
  seen = jobs.to_h { |key| [key, toolchains[key]] }
  missing = seen.select { |_, v| v.nil? }.keys
  missing.each { |file, id| errors << "#{platform}: #{file} job '#{id}' not found or has no setup-xcode step" }
  distinct = seen.values.compact.uniq
  next if distinct.size <= 1

  detail = seen.map { |(file, id), (runner, xcode)| "#{file}/#{id}=#{runner}+#{xcode}" }.join(", ")
  errors << "#{platform}: CI and deploy toolchains differ: #{detail}"
end

if errors.empty?
  PAIRS.each do |platform, jobs|
    runner, xcode = toolchains[jobs.first]
    puts "#{platform}: #{runner} + #{xcode} (#{jobs.map { |f, j| "#{f}/#{j}" }.join(', ')})"
  end
  puts "Toolchains consistent."
else
  errors.each { |e| puts "::error title=Toolchain drift::#{e}" }
  exit 1
end
