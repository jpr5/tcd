# frozen_string_literal: true

require "minitest/autorun"
require "minitest/pride"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "tcd"

# Path to the TCD file for testing - REQUIRED
# Priority:
#   1. ENV["TCD_TEST_FILE"] if set
#   2. Latest *.tcd file in data/ directory (sorted alphabetically)
#   3. Fallback to data/harmonics.tcd (will fail validation if not present)
TCD_TEST_FILE = if ENV["TCD_TEST_FILE"]
    ENV["TCD_TEST_FILE"]
else
    # Auto-detect latest .tcd file in data/ directory
    data_dir = File.expand_path("../data", __dir__)
    if Dir.exist?(data_dir)
        tcd_files = Dir.glob(File.join(data_dir, "*.tcd")).sort
        tcd_files.last if tcd_files.any?
    end
end || File.expand_path("../data/harmonics.tcd", __dir__)

# Validate TCD file is present and readable at test load time
unless File.exist?(TCD_TEST_FILE)
    abort <<~ERROR
        ERROR: TCD test file not found: #{TCD_TEST_FILE}

        Tests require a TCD file. Either:
          1. Set TCD_TEST_FILE environment variable:
             TCD_TEST_FILE=/path/to/harmonics.tcd rake test

          2. Place a TCD file at: data/harmonics.tcd
    ERROR
end

unless File.readable?(TCD_TEST_FILE)
    abort "ERROR: TCD test file not readable: #{TCD_TEST_FILE}"
end
