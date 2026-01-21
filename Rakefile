# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/**/*_test.rb"]
    t.verbose = true
end

task default: :test

desc "Run example program against test TCD file"
task :example do
    tcd_file = ENV["TCD_FILE"] || "data/harmonics.tcd"
    unless File.exist?(tcd_file)
        abort "TCD file not found: #{tcd_file}\nSet TCD_FILE env var or place file in data/harmonics.tcd"
    end
    sh "ruby -Ilib bin/tcd-info #{tcd_file}"
end

desc "Open an IRB console with the gem loaded"
task :console do
    sh "irb -Ilib -rtcd"
end
