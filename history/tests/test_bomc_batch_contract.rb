# frozen_string_literal: true

path = File.expand_path(
  '../generated/SBE-2026.08.13-01/staged/bom_engine/bomc_extension.rb',
  __dir__
)
source = File.read(path, encoding: 'UTF-8')

unless source.match?(/def export\(model, output_path:, profile: DEFAULT_PROFILE, progress: nil, batch_size:/)
  raise 'BOMC 1.0 adapter does not accept the selected batch size'
end
unless source.match?(/build_arguments\[:batch_size\]\s*=\s*batch_size/)
  raise 'BOMC 1.0 adapter does not forward batch size to its canonical builder'
end

puts 'BOMC batch contract: PASS (selected batch reaches BOMC 1.0 graph builder)'
