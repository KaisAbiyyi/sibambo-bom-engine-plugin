require 'json'
require 'benchmark'
ROOT=File.expand_path('../../..', __dir__)
require "#{ROOT}/bom_engine/bomc_writer"
require "#{ROOT}/bom_engine/bomc_decoder"
require "#{ROOT}/bom_engine/bomc_validator"
path = ARGV[0]; profile=(ARGV[1]||'visual').to_sym; src=(ARGV[2]||0).to_i
t=Process.clock_gettime(Process::CLOCK_MONOTONIC)
graph = JSON.parse(File.read(path), symbolize_names: true)
puts "json parse #{(Process.clock_gettime(Process::CLOCK_MONOTONIC)-t).round(2)}s"
stage_t=Hash.new(0.0); last=[nil,Process.clock_gettime(Process::CLOCK_MONOTONIC)]; calls=Hash.new(0)
cp=lambda do |**e|
  now=Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stage_t[last[0]]+=now-last[1] if last[0]
  last[0]=e[:stage]; last[1]=now; calls[e[:stage]]+=1
end
t=Process.clock_gettime(Process::CLOCK_MONOTONIC)
res = BOMEngine::BOMCWriter.pack(graph, profile: profile, source_skp_bytes: src, base_path: File.dirname(path), checkpoint: cp)
el=Process.clock_gettime(Process::CLOCK_MONOTONIC)-t
puts "pack #{el.round(2)}s total bytes=#{res[:bytes].bytesize}"
res[:metrics][:sections].sort_by{|k,v|-v[:stored_bytes]}.each{|k,v| puts "  %-18s raw=%9d stored=%9d count=%d" % [k,v[:raw_bytes],v[:stored_bytes],v[:count]]}
puts "stage times (checkpoint-attributed):"; stage_t.sort_by{|k,v|-v}.each{|k,v| puts "  %-20s %.2fs calls=%d" % [k,v,calls[k]]}
File.binwrite(File.basename(path,'.json')+".#{profile}.bomc", res[:bytes])
t=Process.clock_gettime(Process::CLOCK_MONOTONIC)
dec=BOMEngine::BOMCDecoder.decode(res[:bytes])
puts "decode #{(Process.clock_gettime(Process::CLOCK_MONOTONIC)-t).round(2)}s"
t=Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
rep=BOMEngine::BOMCValidator.validate_profile!(source: graph, decoded: dec, profile: profile)
puts "validate #{(Process.clock_gettime(Process::CLOCK_MONOTONIC)-t).round(2)}s passed=#{rep[:passed]}"
rescue => e
puts "validate #{(Process.clock_gettime(Process::CLOCK_MONOTONIC)-t).round(2)}s ERR #{e.class}: #{e.message[0,300]}"
end
