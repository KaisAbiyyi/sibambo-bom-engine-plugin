# frozen_string_literal: true
require 'json'
require 'digest'
require 'securerandom'
require 'fileutils'

# Host evidence only. No PNG encoding, WebP search, color mapping or geometry.
module ExactColorMapPixels
  class Cancelled < StandardError; end
  MAX_TOTAL_PIXELS=128_000_000
  module_function

  def descriptor(path)
    {'file'=>File.basename(path),'bytes'=>File.size(path),'sha256'=>Digest::SHA256.file(path).hexdigest}
  end

  def save_frame(image,path,width,height,&checkpoint)
    bits,padding=image.bits_per_pixel,image.row_padding
    unless image.width==width && image.height==height && [24,32].include?(bits) && padding.is_a?(Integer) && (0..3).cover?(padding)
      raise ArgumentError,'Unsupported host frame layout'
    end
    data=image.data
    expected=(width*(bits/8)+padding)*height
    raise ArgumentError,'Host frame byte length mismatch' unless data.is_a?(String) && data.bytesize==expected
    raise ArgumentError,'Frame output already exists' if File.exist?(path) || File.exist?(path+'.part')
    File.open(path+'.part',File::WRONLY | File::CREAT | File::EXCL | File::BINARY) do |file|
      offset=0
      while offset<data.bytesize
        chunk=data.byteslice(offset,4*1024*1024)
        file.write(chunk)
        offset+=chunk.bytesize
        checkpoint.call('write_host_frame') if checkpoint
      end
    end
    File.rename(path+'.part',path)
    descriptor(path).merge('width'=>width,'height'=>height,'bits_per_pixel'=>bits,'row_padding'=>padding,
      'channel_layout'=>bits==24 ? 'BGR' : 'BGRA','row_order'=>'top_down')
  end

  def capture_texture(texture,directory,index,codec:,loader:,&checkpoint)
    width,height=texture.image_width,texture.image_height
    codec.validate_dimensions(width,height)
    raise ArgumentError,'Invalid texture index' unless index.is_a?(Integer) && (0...64).cover?(index)
    prefix=File.join(directory,"texture-#{index}")
    raise ArgumentError,'Texture output already exists' unless Dir.glob(prefix+'.*').empty?
    timings={}
    measure=lambda do |phase,&action|
      checkpoint.call(phase) if checkpoint
      started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value=action.call
      timings[phase]=Process.clock_gettime(Process::CLOCK_MONOTONIC)-started
      value
    end
    native=prefix+'.native.jpg'
    measure.call('extract_native_jpeg') do
      raise 'Native JPEG extraction failed' unless texture.write(native,false) && File.file?(native) && File.size(native)>0
    end
    jpeg_path=prefix+'.base.jpg'
    measure.call('normalize_jpeg') do
      raise ArgumentError,'JPEG resource bound' if File.size(native)>codec::MAX_JPEG_BYTES
      bytes=codec.normalize_jpeg(File.binread(native),width,height)
      File.open(jpeg_path,File::WRONLY | File::CREAT | File::EXCL | File::BINARY) { |file| file.write(bytes) }
    end
    base=measure.call('capture_base_frame') do
      save_frame(loader.call(jpeg_path),prefix+'.base.raw',width,height,&checkpoint)
    end
    target=measure.call('capture_target_frame') do
      save_frame(texture.image_rep(true),prefix+'.target.raw',width,height,&checkpoint)
    end
    {'width'=>width,'height'=>height,'native_jpeg'=>descriptor(native),'jpeg'=>descriptor(jpeg_path),
      'base_frame'=>base,'target_frame'=>target,'stage_seconds'=>timings}
  end

  def configure(root,engine)
    raise 'Pixel capture already running' if @running
    @root,@engine=root,engine
  end

  def start(limit:4,min_pixels:4_000_001,max_pixels:32_000_000)
    raise 'Pixel capture already running' if @running
    raise 'Windows SketchUp runtime required' unless defined?(Sketchup) && defined?(UI) && RUBY_PLATFORM.match?(/mswin|mingw/i)
    unless limit.is_a?(Integer) && (1..64).cover?(limit) && min_pixels.is_a?(Integer) && max_pixels.is_a?(Integer) && min_pixels>0 && min_pixels<=max_pixels && max_pixels<=32_000_000
      raise ArgumentError,'Invalid capture limits'
    end
    @model=Sketchup.active_model
    raise 'Open a saved model without unsaved changes' unless @model && File.file?(@model.path.to_s) && !@model.modified?
    manifest=JSON.parse(File.read(File.join(@root,'manifest.json')))
    manifest.fetch('files').each do |relative,sha|
      raise "Capture kit changed: #{relative}" unless Digest::SHA256.file(File.join(@root,relative)).hexdigest==sha
    end
    textures=@model.materials.select do |material|
      t=material.texture
      t && %w[.jpg .jpeg].include?(File.extname(t.filename.to_s).downcase) && (min_pixels..max_pixels).cover?(t.image_width*t.image_height)
    end.sort_by { |m| [-m.texture.image_width*m.texture.image_height,m.name.to_s] }
    selected=textures.first(limit)
    raise 'No eligible textures' if selected.empty?
    raise 'Capture pixel budget exceeded; reduce limit' if selected.sum { |m| m.texture.image_width*m.texture.image_height }>MAX_TOTAL_PIXELS
    @session=File.join(@root,'results',"pixels-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@session)
    @report={'schema'=>'exact-color-map-host-pixels-v1','status'=>'running','ready'=>false,
      'source_tree_sha256'=>manifest.fetch('source_tree_sha256'),'tooling_sha256'=>manifest.fetch('tooling_sha256'),
      'required_loader'=>manifest.fetch('required_loader'),'source_path'=>@model.path,
      'source_sha256'=>Digest::SHA256.file(@model.path).hexdigest,'source_bytes'=>File.size(@model.path),
      'ruby'=>RUBY_DESCRIPTION,'sketchup_version'=>Sketchup.version,'pixel_layout'=>'windows-bgr-top-down',
      'eligible_textures'=>textures.length,'sampled_textures'=>selected.length,'textures'=>[]}
    @cancelled=false
    @running=true
    @fiber=Fiber.new do
      selected.each_with_index do |material,index|
        validate_runtime!
        row=capture_texture(material.texture,@session,index,codec:@engine::BOMCJpegColorMap,
          loader: ->(path) { Sketchup::ImageRep.new(path) }) do |phase|
          Fiber.yield("#{index+1}/#{selected.length}: #{phase}")
          validate_runtime!
        end
        @report['textures'] << row.merge('material'=>material.name)
        save_report
      end
      validate_runtime!
      raise 'Saved model file changed' unless Digest::SHA256.file(@model.path).hexdigest==@report['source_sha256']
      :capture_done
    end
    save_report
    UI.start_timer(0.05,false) { resume_step }
    @session
  end

  def validate_runtime!
    raise Cancelled,'Pixel capture cancelled' if @cancelled
    raise 'Active model changed' unless Sketchup.active_model==@model && !@model.modified?
  end
  def cancel
    @cancelled=true
  end
  def save_report
    File.write(File.join(@session,'report.json'),JSON.pretty_generate(@report))
  end
  def resume_step
    phase=@fiber.resume
    if phase != :capture_done
      @report['phase']=phase
      save_report
      Sketchup.set_status_text("Host pixels — #{phase} — no model export")
      UI.start_timer(0.05,false) { resume_step }
    else
      finish('captured_pending_offline_verification')
    end
  rescue StandardError => error
    @report['error']="#{error.class}: #{error.message}"
    finish(error.is_a?(Cancelled) ? 'cancelled' : 'failed')
  end
  def finish(status)
    @report['status']=status
    save_report
    @running=false
    @fiber=nil
    Sketchup.set_status_text('Host pixel capture ended; ready=false')
    puts "#{status}: #{@session} (ready=false)"
    UI.messagebox("Host pixel capture: #{status}\n#{@session}\nSend result to Codex. No model export or installation.")
  end
end
