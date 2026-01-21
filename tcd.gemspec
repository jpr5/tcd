# frozen_string_literal: true

require_relative "lib/tcd/version"

Gem::Specification.new do |spec|
    spec.name          = "tcd"
    spec.version       = TCD::VERSION
    spec.authors       = ["Jordan Ritter"]
    spec.email         = ["jpr5@darkridge.com"]

    spec.summary       = "Pure Ruby reader for XTide TCD (Tidal Constituent Database) files"
    spec.description   = "A pure Ruby gem for reading TCD files containing tidal harmonic " \
                         "constituents and station data used by XTide for tide predictions. " \
                         "No C extensions or external dependencies required."
    spec.homepage      = "https://github.com/jpr5/tcd"
    spec.license       = "MIT"

    spec.required_ruby_version = ">= 2.7.0"

    spec.metadata = {
        "homepage_uri"      => spec.homepage,
        "source_code_uri"   => spec.homepage,
        "changelog_uri"     => "#{spec.homepage}/blob/master/CHANGELOG.md",
        "bug_tracker_uri"   => "#{spec.homepage}/issues",
        "documentation_uri" => "https://rubydoc.info/gems/tcd",
        "rubygems_mfa_required" => "true"
    }

    spec.files         = Dir["lib/**/*.rb", "bin/*", "LICENSE", "README.md", "CHANGELOG.md"]
    spec.bindir        = "bin"
    spec.executables   = ["tcd-info"]
    spec.require_paths = ["lib"]

    # No runtime dependencies - pure Ruby stdlib only

    # Development dependencies
    spec.add_development_dependency "minitest", "~> 5.0"
    spec.add_development_dependency "rake", "~> 13.0"
end
