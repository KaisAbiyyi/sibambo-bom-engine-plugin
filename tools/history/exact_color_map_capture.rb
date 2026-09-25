# frozen_string_literal: true
require 'json'
require 'digest'
require 'securerandom'
require 'fileutils'

module ExactColorMapPreview
  class Cancelled < StandardError; end
  def self.configure(root,engine)
    raise 'A color-map capture is already running' if @running
    @root,@engine=root,engine
  end
  def self.cancel
    @cancelled=true
  end
  # Checking cancellation stays frequent; crossing into the SketchUp UI does not.
  def self.progress_checkpoint(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      cancelled: -> { @cancelled }, publish:)
    last_update=nil
    lambda do |processed,total|
      raise Cancelled,'Capture cancelled' if cancelled.call
      now=clock.call
      if last_update.nil? || now-last_update>=0.25
        publish.call(processed,total)
        last_update=clock.call
      end
    end
  end
  def self.start(limit:4,min_pixels:4_000_001,max_pixels:32_000_000)
    raise 'A color-map capture is already running' if @running
    raise ArgumentError,'Invalid sample limits' unless limit.is_a?(Integer) && (1..64).cover?(limit) &&
      min_pixels.is_a?(Integer) && max_pixels.is_a?(Integer) && min_pixels>0 && min_pixels<=max_pixels && max_pixels<=32_000_000
    raise 'SketchUp runtime required' unless defined?(Sketchup) && defined?(UI)
    @model=Sketchup.active_model
    raise 'Save the open model first; unsaved edits are not allowed' unless @model && File.file?(@model.path.to_s) && !@model.modified?
    manifest=JSON.parse(File.read(File.join(@root,'manifest.json')))
    manifest.fetch('files').each do |path,sha|
      raise "Capture kit changed: #{path}" unless Digest::SHA256.file(File.join(@root,path)).hexdigest==sha
    end
    all=@model.materials.select do |mat|
      tex=mat.texture
      tex && %w[.jpg .jpeg].include?(File.extname(tex.filename.to_s).downcase) &&
        (min_pixels..max_pixels).cover?(tex.image_width*tex.image_height)
    end.sort_by { |mat| [-mat.texture.image_width*mat.texture.image_height,mat.name.to_s] }
    @queue=all.first(limit)
    raise 'No JPEG textures in the requested pixel range' if @queue.empty?
    @session=File.join(@root,'results',"capture-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@session)
    @report={'schema'=>'exact-color-map-capture-v1','ready'=>false,'status'=>'running',
      'source_path'=>@model.path,'source_sha256'=>Digest::SHA256.file(@model.path).hexdigest,'source_bytes'=>File.size(@model.path),
      'source_tree_sha256'=>manifest.fetch('source_tree_sha256'),'tooling_sha256'=>manifest.fetch('tooling_sha256'),
      'required_loader'=>manifest.fetch('required_loader'),'sketchup_version'=>Sketchup.version,'ruby'=>RUBY_DESCRIPTION,
      'eligible_textures'=>all.length,'sampled_textures'=>@queue.length,'min_pixels'=>min_pixels,'max_pixels'=>max_pixels,'textures'=>[]}
    @cancelled=false
    @running=true
    save_report
    puts "Exact color-map texture test: #{@queue.length} textures; no geometry export. #{@session}"
    UI.start_timer(0.1,false) { process_next }
    @session
  end
  def self.save_report
    File.write(File.join(@session,'report.json'),JSON.pretty_generate(@report))
  end
  def self.process_next
    raise Cancelled,'Capture cancelled' if @cancelled
    raise 'Active model changed during capture' unless Sketchup.active_model==@model && !@model.modified?
    material=@queue.shift
    unless material
      raise 'Saved model file changed during capture' unless Digest::SHA256.file(@model.path).hexdigest==@report['source_sha256']
      return finish('captured_pending_browser_verification')
    end
    index=@report['textures'].length
    started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
    checkpoint=progress_checkpoint(publish: lambda do |processed,total|
      Sketchup.set_status_text("Exact textures #{index+1}/#{@report['sampled_textures']} — #{material.name} — #{processed}/#{total}")
    end)
    result=@engine::BOMCTextureOptimizer.stage(texture:material.texture,directory:@session,basename:"texture-#{index}",
      source_path:material.texture.filename,profile: :exact,allow_jpeg_color_map:true,&checkpoint)
    entry={'material'=>material.name,'width'=>material.texture.image_width,'height'=>material.texture.image_height,
      'file'=>result[:filename],'sha256'=>Digest::SHA256.file(result[:path]).hexdigest,'bytes'=>File.size(result[:path]),
      'seconds'=>Process.clock_gettime(Process::CLOCK_MONOTONIC)-started,'evidence'=>result[:evidence]}
    if result[:filename].end_with?('.jcm')
      map=@engine::BOMCJpegColorMap.parse(File.binread(result[:path]))
      entry['expected_rgba_sha256']=map[:output_hash].unpack1('H*')
    end
    @report['textures'] << entry
    save_report
    puts "#{index+1}/#{@report['sampled_textures']} #{material.name}: #{result[:filename]} (#{entry['bytes']} bytes)"
    UI.start_timer(0.1,false) { process_next }
  rescue StandardError => error
    @report['error']="#{error.class}: #{error.message}"
    finish(error.is_a?(Cancelled) ? 'cancelled' : 'failed')
  end
  def self.finish(status)
    @report['status']=status
    save_report
    @running=false
    Sketchup.set_status_text('Exact texture capture ended; release remains not ready')
    puts "#{status}: #{File.join(@session,'report.json')} (ready=false)"
    UI.messagebox("Exact texture test: #{status}\n#{@session}\nSend this result to Codex. No model export or installation was performed.")
    @session
  end
end
