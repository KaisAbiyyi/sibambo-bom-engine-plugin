# frozen_string_literal: true
# Standalone PNG optimizer comparison: compare old and new implementations by
# setting PNG_OPTIMIZER_RB to an unmodified historical module in a new process.
require 'benchmark'
require 'digest'
require 'tmpdir'
require 'zlib'
require_relative '../bomc_png_optimizer' unless ENV['PNG_OPTIMIZER_RB']
load ENV['PNG_OPTIMIZER_RB'] if ENV['PNG_OPTIMIZER_RB']

width=Integer(ARGV.fetch(0,'512'))
height=Integer(ARGV.fetch(1,'512'))
raise 'bounds exceeded' unless width.between?(1,2048) && height.between?(1,2048)
chunk=lambda do |type,data|
  [data.bytesize].pack('N') + type.b + data + [Zlib.crc32(type.b+data)].pack('N')
end
rows=height.times.map do |y|
  row=width.times.map do |x|
    [((x*11+y*3)&255),((x+y*7)&255),((x*3+y*13)&255),255].pack('C4')
  end.join.b
  "\0".b + row
end.join.b
source=BOMEngine::BOMCPngOptimizer::SIGNATURE +
  chunk.call('IHDR',[width,height,8,6,0,0,0].pack('NNC5')) +
  chunk.call('IDAT',Zlib::Deflate.deflate(rows,6)) + chunk.call('IEND',''.b)
dir=ENV['SIBAMBO_BENCH_TMP'] || 'D:/projects/sibambo/scratch'
Dir.mktmpdir('png-repack-',dir) do |root|
  input=File.join(root,'input.png'); output=File.join(root,'output.png')
  File.binwrite(input,source)
  result=nil
  elapsed=Benchmark.realtime do
    result=BOMEngine::BOMCPngOptimizer.optimize(source_path:input,output_path:output)
  end
  puts "#{width}x#{height} source_bytes=#{source.bytesize} output_bytes=#{result && result[:bytes]} seconds=#{elapsed.round(3)} output_sha=#{result && Digest::SHA256.file(output).hexdigest} strategy=#{result && result[:strategy]}"
end
