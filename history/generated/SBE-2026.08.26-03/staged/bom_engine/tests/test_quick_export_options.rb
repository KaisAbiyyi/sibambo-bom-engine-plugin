# Run with standalone Ruby/JRuby; no SketchUp API is needed for tuning tests.

require_relative '../quick_export_options'

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
  puts "PASS: #{message}"
end

options = SibamboHistory::V20260826_03::QuickExportOptions
assert(options.recommended_batch(cores: 2, calibration_iterations: 10) == 8, 'low-end profile gets a responsive batch')
assert(options.recommended_batch(cores: 4, calibration_iterations: 400) == 16, 'mid-range profile gets balanced batch')
assert(options.recommended_batch(cores: 8, calibration_iterations: 1_000) == 24, 'fast eight-core profile gets higher throughput batch')
assert(options.recommended_batch(cores: 16, calibration_iterations: 1_000) == 64, 'high-core profile gets a higher throughput batch')
assert(options.recommended_batch(cores: 24, calibration_iterations: 1_000) == 96, 'workstation profile gets a fast default batch')
assert(options.normalize_batch(32, fallback: 16) == 32, 'allowed manual batch is preserved')
assert(options.normalize_batch(512, fallback: 16) == 512, 'high turbo batch is preserved')
assert(options.normalize_batch(8_192, fallback: 16) == 8_192, 'extreme power-of-two turbo batch is preserved')
assert(options.normalize_batch(999, fallback: 24) == 24, 'invalid manual batch falls back to the safe recommendation')

puts 'Quick Export Options Tests: ALL PASSED'
