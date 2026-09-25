# frozen_string_literal: true
require 'json'
require 'digest'
require 'securerandom'
require 'fileutils'
require_relative '../../bom_engine/bomc_jpeg_color_map'

module ExactColorMapOffline
  module_function
  def sha?(value)
    value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
  end
  def json(path)
    raise ArgumentError,'Report too large' if File.size(path)>1024*1024
    JSON.parse(File.read(path))
  end
  def checked_file(root,relative)
    raise ArgumentError,'Unsafe file path' unless relative.is_a?(String) && !relative.empty? && !relative.include?('..') && !relative.match?(/\A[\\\/]|[:\\]/)
    file=File.join(root,relative)
    prefix=File.realpath(root).tr('\\','/').downcase+'/'
    unless File.file?(file) && !File.symlink?(file) && File.realpath(file).tr('\\','/').downcase.start_with?(prefix)
      raise ArgumentError,'Missing or escaped file'
    end
    file
  end
  def frame_size(frame)
    width,height,bits,padding=frame.values_at('width','height','bits_per_pixel','row_padding')
    BOMEngine::BOMCJpegColorMap.validate_dimensions(width,height)
    unless [24,32].include?(bits) && padding.is_a?(Integer) && (0..3).cover?(padding) &&
        frame['channel_layout']==(bits==24 ? 'BGR' : 'BGRA') && frame['row_order']=='top_down'
      raise ArgumentError,'Unsupported frame layout'
    end
    (width*(bits/8)+padding)*height
  end
  def canonical_rgba(bytes,frame)
    raise ArgumentError,'Frame length mismatch' unless bytes.bytesize==frame_size(frame)
    width,height,bits,padding=frame.values_at('width','height','bits_per_pixel','row_padding')
    row_bytes=width*(bits/8)
    result=+''.b
    height.times do |row|
      offset=row*(row_bytes+padding)
      # Same canonical conversion as runtime staging. Large integer arrays
      # were measurably slower on captured Windows frames; avoid allocating
      # one array per pixel while retaining exact padding/alpha semantics.
      width.times do
        result << bytes.getbyte(offset+2) << bytes.getbyte(offset+1) << bytes.getbyte(offset)
        result << (bits==32 ? bytes.getbyte(offset+3) : 255)
        offset+=bits/8
      end
    end
    result
  end
  def validate_blob(session,entry,limit)
    unless entry.is_a?(Hash) && entry['file'].is_a?(String) && entry['file'].match?(/\Atexture-\d+\.(base|target|native)\.(raw|jpg)\z/) &&
        entry['bytes'].is_a?(Integer) && entry['bytes']>0 && entry['bytes']<=limit && sha?(entry['sha256'])
      raise ArgumentError,'Invalid blob descriptor'
    end
    file=checked_file(session,entry['file'])
    raise ArgumentError,'Blob size/hash mismatch' unless File.size(file)==entry['bytes'] && Digest::SHA256.file(file).hexdigest==entry['sha256']
    file
  end
  def read_blob(session,entry,limit)
    file=validate_blob(session,entry,limit)
    bytes=File.binread(file)
    raise ArgumentError,'Blob changed while reading' unless bytes.bytesize==entry['bytes'] && Digest::SHA256.hexdigest(bytes)==entry['sha256']
    bytes
  end
  def convert(report_path)
    report_path=File.expand_path(report_path)
    session=File.dirname(report_path);kit=File.expand_path('../..',session)
    report=json(report_path);manifest=json(File.join(kit,'manifest.json'))
    unless report['schema']=='exact-color-map-host-pixels-v1' && report['status']=='captured_pending_offline_verification' &&
        report['ready']==false && report['pixel_layout']=='windows-bgr-top-down' && sha?(report['source_sha256'])
      raise ArgumentError,'Incomplete or unsupported host capture'
    end
    unless manifest['schema']=='exact-color-map-preview-v1' && manifest['required_loader']=='bomc-next-jcm-v1'
      raise ArgumentError,'Unsupported capture kit'
    end
    %w[source_tree_sha256 tooling_sha256 required_loader].each do |field|
      raise ArgumentError,'Capture identity mismatch' unless report[field]==manifest[field]
    end
    inventory=manifest['files']
    raise ArgumentError,'Missing snapshot inventory' unless inventory.is_a?(Hash) && !inventory.empty?
    inventory.each do |relative,expected|
      raise ArgumentError,'Snapshot hash mismatch' unless sha?(expected) && Digest::SHA256.file(checked_file(kit,relative)).hexdigest==expected
    end
    codec_path=File.expand_path('../../bom_engine/bomc_jpeg_color_map.rb',__dir__)
    unless manifest.dig('source_files','bom_engine/bomc_jpeg_color_map.rb')==Digest::SHA256.file(codec_path).hexdigest
      raise ArgumentError,'Offline codec differs from captured source; rebuild a matching kit'
    end
    textures=report['textures'];count=report['sampled_textures']
    unless count.is_a?(Integer) && (1..64).cover?(count) && textures.is_a?(Array) && textures.length==count
      raise ArgumentError,'Capture count mismatch'
    end
    total=0;seen={}
    textures.each do |entry|
      width,height=entry.values_at('width','height')
      BOMEngine::BOMCJpegColorMap.validate_dimensions(width,height)
      total+=width*height
      raise ArgumentError,'Capture aggregate pixel bound' if total>128_000_000
      %w[jpeg base_frame target_frame].each do |kind|
        blob=entry.fetch(kind)
        raise ArgumentError,'Duplicate evidence path' if seen[blob['file']]
        seen[blob['file']]=true
        if kind!='jpeg'
          expected=frame_size(blob)
          raise ArgumentError,'Frame dimensions or length mismatch' unless blob['width']==width && blob['height']==height && blob['bytes']==expected
        end
        validate_blob(session,blob,kind=='jpeg' ? BOMEngine::BOMCJpegColorMap::MAX_JPEG_BYTES : 128_100_000)
      end
    end
    output=File.join(kit,'results',"offline-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}")
    Dir.mkdir(output)
    result=report.reject { |key,_| %w[textures phase error].include?(key) }.merge(
      'schema'=>'exact-color-map-offline-v1','status'=>'processing','textures'=>[],
      'raw_capture_file'=>File.basename(session)+'/report.json','raw_capture_sha256'=>Digest::SHA256.file(report_path).hexdigest,
      'offline_tool_sha256'=>Digest::SHA256.file(__FILE__).hexdigest)
    result_path=File.join(output,'report.json')
    begin
      textures.each_with_index do |entry,index|
        started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
        jpeg=read_blob(session,entry['jpeg'],BOMEngine::BOMCJpegColorMap::MAX_JPEG_BYTES)
        base=canonical_rgba(read_blob(session,entry['base_frame'],128_100_000),entry['base_frame'])
        target=canonical_rgba(read_blob(session,entry['target_frame'],128_100_000),entry['target_frame'])
        payload=BOMEngine::BOMCJpegColorMap.encode(jpeg:jpeg,base_rgba:base,target_rgba:target,width:entry['width'],height:entry['height'])
        raise "Texture #{index} is not representable; retain existing lossless encoding" unless payload
        filename="texture-#{index}.jcm"
        File.binwrite(File.join(output,filename),payload)
        result['textures'] << {'material'=>entry['material'],'width'=>entry['width'],'height'=>entry['height'],
          'file'=>filename,'bytes'=>payload.bytesize,'sha256'=>Digest::SHA256.hexdigest(payload),
          'expected_rgba_sha256'=>Digest::SHA256.hexdigest(target),'base_rgba_sha256'=>Digest::SHA256.hexdigest(base),
          'seconds'=>Process.clock_gettime(Process::CLOCK_MONOTONIC)-started}
        File.write(result_path,JSON.pretty_generate(result))
      end
      raise 'Capture changed during processing' unless Digest::SHA256.file(report_path).hexdigest==result['raw_capture_sha256']
      result['status']='captured_pending_browser_verification'
    rescue StandardError => error
      result['status']='failed';result['error']="#{error.class}: #{error.message}"
    ensure
      File.write(result_path,JSON.pretty_generate(result))
    end
    result_path
  end
end
if __FILE__==$PROGRAM_NAME
  abort 'Usage: ruby process_exact_color_map_pixels.rb <host capture report.json>' unless ARGV.length==1
  output=ExactColorMapOffline.convert(ARGV[0])
  puts output
  exit(ExactColorMapOffline.json(output)['status']=='captured_pending_browser_verification' ? 0 : 2)
end
