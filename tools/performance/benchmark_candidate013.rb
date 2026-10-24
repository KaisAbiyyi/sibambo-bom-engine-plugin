# Offline component evidence only. Does not load SketchUp or modify SKPs.
require 'json'
require 'digest'
require 'fileutils'
repo, fixture_directory, output_directory = ARGV
abort 'usage: ruby benchmark_candidate013.rb REPO PNG_FIXTURES OUTPUT' unless output_directory
require File.join(File.expand_path(repo), 'bom_engine/bomc_png_optimizer')
FileUtils.mkdir_p(output_directory)
optimizer = BOMEngine::BOMCPngOptimizer
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
results = Dir.glob(File.join(fixture_directory, '*.png')).sort.map do |path|
  parsed = optimizer.send(:parse, File.binread(path))
  last = started = clock.call; max_gap = 0.0; events = 0
  callback = ->(*) { now = clock.call; max_gap = [max_gap, (now-last)*1000].max; last = now; events += 1 }
  target = File.join(output_directory, File.basename(path))
  result = optimizer.optimize(source_path: path, output_path: target, checkpoint: callback)
  callback.call
  {fixture: File.basename(path), pixels: parsed[:pixels], milliseconds: (clock.call-started)*1000,
   max_callback_gap_ms: max_gap, checkpoints: events, selected: result,
   input_sha256: Digest::SHA256.file(path).hexdigest,
   output_sha256: result && Digest::SHA256.file(target).hexdigest,
   native: false, source_fidelity_proven: false}
end
File.write(File.join(output_directory, 'png-benchmark.json'), JSON.pretty_generate(results))
puts JSON.generate(results)
