# frozen_string_literal: true

# Fails if project.yml (what XcodeGen, CI and the shipped builds resolve) and
# Package.swift (what Dependabot reads and bumps) disagree on a package's
# minimum version. Dependabot only edits Package.swift, so without this check a
# major bump goes green while every build still compiles the old major.
#
#   ruby scripts/check-package-pins.rb
require "yaml"

ROOT = File.expand_path("..", __dir__)

def normalize(url)
  url.to_s.downcase.sub(/\.git\z/, "").chomp("/")
end

swift = File.read(File.join(ROOT, "Package.swift"))
swift_pins = swift.scan(/\.package\(\s*url:\s*"([^"]+)"\s*,\s*from:\s*"([^"]+)"/)
                  .to_h { |url, from| [normalize(url), from] }

packages = YAML.safe_load_file(File.join(ROOT, "project.yml"))["packages"] || {}
yml_pins = packages.values.to_h { |pkg| [normalize(pkg["url"]), pkg["from"].to_s] }

errors = []
(swift_pins.keys | yml_pins.keys).sort.each do |url|
  swift_from = swift_pins[url]
  yml_from = yml_pins[url]
  next if swift_from == yml_from

  errors << "#{url}: Package.swift from #{swift_from.inspect}, project.yml from #{yml_from.inspect}"
end

if errors.empty?
  puts "Package pins match (#{swift_pins.size} package(s))."
else
  warn "Package.swift and project.yml disagree:"
  errors.each { |e| warn "  #{e}" }
  warn "Update both (Dependabot only bumps Package.swift)."
  exit 1
end
