require 'json'
ROOT=File.expand_path('../../..', __dir__)
require "#{ROOT}/bom_engine/bomc_size_gate"
path=ARGV[0]; variant=ARGV[1]
graph = JSON.parse(File.read(path), symbolize_names: true)
graph[:source_digest] = 'f'*64 if variant.include?('digest')
if variant.include?('gate')
  module BOMEngine::BOMC::PositionCodec
    class << self
      alias_method :orig_area_gate, :area_gate
      def area_gate(source, decoded, loops)
        return [0.0, true] if source.equal?(decoded) || source == decoded
        @src_cache ||= {}
        key = source.object_id
        cache = (@src_cache[key] ||= Array(loops).map { |l| l.length < 3 ? nil : (v = newell_vector(source, l); [v, BOMEngine::BOMC::CodecMath.vector_length(v) * 0.5]) })
        max_e = 0.0; ok = true
        Array(loops).each_with_index do |l, i|
          c = cache[i]; next unless c
          sv, sa = c
          dv = newell_vector(decoded, l); da = Math.sqrt(dv[0]*dv[0]+dv[1]*dv[1]+dv[2]*dv[2]) * 0.5
          e = (sa - da).abs; max_e = e if e > max_e
          tol = [1.0e-6, sa * 0.001].max
          if e > tol + 1e-12 || (sa > 1.0e-6 && sv[0]*dv[0]+sv[1]*dv[1]+sv[2]*dv[2] <= 0.0)
            ok = false; break
          end
        end
        [max_e, ok]
      end
    end
  end
end
if variant.include?('lvl6')
  module BOMEngine::BOMC::CodecMath
    def self.compressed_size(bytes) = Zlib::Deflate.deflate(bytes, 6).bytesize
  end
end
GC.auto_compact = false
if variant.include?('gc')
  # emulate a larger heap growth factor (RUBY_GC_HEAP_GROWTH_FACTOR) via env in caller
end
t=Process.clock_gettime(Process::CLOCK_MONOTONIC)
res = BOMEngine::BOMCSizeGate.compile_candidate(graph, source_info: {available: true, bytes: 41785434}, profile: :visual, base_path: File.dirname(path))
puts "#{variant}: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC)-t).round(2)}s bytes=#{res[:bytes].bytesize} gc_count=#{GC.count}"
