# frozen_string_literal: true
# Standalone native Windows Ruby verification benchmark; never needs SketchUp.
# Example: ruby colorize_verify_benchmark.rb 1024 768
# To compare prior implementations, use a separate process with its source
# copy supplied as the COLORIZE_RB environment variable.
require 'benchmark'
require_relative '../bomc_sketchup_colorize' unless ENV['COLORIZE_RB']
load ENV['COLORIZE_RB'] if ENV['COLORIZE_RB']

width = Integer(ARGV.fetch(0,'1024'))
height = Integer(ARGV.fetch(1,'768'))
palette_size = Integer(ARGV.fetch(2,'4'))
raise 'bounded benchmark dimensions required' unless width.between?(1,2048) && height.between?(1,2048)
raise 'invalid palette size' unless palette_size.between?(1,262_144)
colorize = BOMEngine::BOMCSketchupColorize
deltas={h:92.58741048890613,l:0.13725490868091583,s:-0.11229892646129502}
palette=palette_size.times.map do |i|
  key=(i*2_654_435_761)&0xffffff
  [(key>>16)&255,(key>>8)&255,key&255,[0,64,127,255][i%4]]
end
source_pixel=palette.map do |r,g,b,a|
  (Gem.win_platform? ? [b,g,r,a] : [r,g,b,a]).pack('C4')
end
target_pixel=palette.map do |r,g,b,a|
  rr,rg,rb=colorize.colorize_pixel(r,g,b,*deltas.values,true)
  (Gem.win_platform? ? [rb,rg,rr,a] : [rr,rg,rb,a]).pack('C4')
end
rep = Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data)
source_data=height.times.map { |y| width.times.map { |x| source_pixel[(y*width+x)%palette_size] }.join.b }.join.b
target_data=height.times.map { |y| width.times.map { |x| target_pixel[(y*width+x)%palette_size] }.join.b }.join.b
source=rep.new(width,height,32,0,source_data)
target=rep.new(width,height,32,0,target_data)
result=nil
duration=Benchmark.realtime do
  result=colorize.verify(uncolorized:source,colorized:target,mode: :shift,deltas:deltas,max_seconds:600)
end
raise "Proof failed: #{result}" unless result[:passed]
puts "#{width}x#{height} pixels=#{width*height} seconds=#{duration.round(3)} throughput_px_per_sec=#{((width*height)/duration).round} base_sha=#{result[:base_pixel_sha256]} output_sha=#{result[:output_pixel_sha256]}"
