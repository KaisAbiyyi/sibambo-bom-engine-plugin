require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../../tools/history/build_exact_color_map_preview'
require_relative '../../tools/history/exact_color_map_pixels'
require_relative '../../bom_engine/bomc_jpeg_color_map'
offline=File.expand_path('../../tools/history/process_exact_color_map_pixels.rb',__dir__)
require offline if File.file?(offline)

class ExactColorMapOfflineTest < Minitest::Test
  def fixture
    assert defined?(ExactColorMapOffline),'Offline processor missing'
    Dir.mktmpdir do |root|
      kit=File.join(root,'kit');manifest=ExactColorMapPreviewBuilder.build(output:kit)
      session=File.join(kit,'results','pixels-test');FileUtils.mkdir_p(session)
      jpeg=[255,216,255,192,0,17,8,0,1,0,2,3,1,17,0,2,17,0,3,17,0,255,218,0,12,3,1,0,2,0,3,0,0,63,0,1,255,217].pack('C*')
      File.binwrite(File.join(session,'texture-0.base.jpg'),jpeg)
      frame=Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data)
      base=ExactColorMapPixels.save_frame(frame.new(2,1,24,2,[30,20,10,60,50,40,99,99].pack('C*')),File.join(session,'texture-0.base.raw'),2,1)
      target=ExactColorMapPixels.save_frame(frame.new(2,1,32,0,[33,22,11,255,66,55,44,255].pack('C*')),File.join(session,'texture-0.target.raw'),2,1)
      report={'schema'=>'exact-color-map-host-pixels-v1','status'=>'captured_pending_offline_verification','ready'=>false,
        'pixel_layout'=>'windows-bgr-top-down','sampled_textures'=>1,'source_sha256'=>'a'*64,
        'source_tree_sha256'=>manifest['source_tree_sha256'],'tooling_sha256'=>manifest['tooling_sha256'],'required_loader'=>manifest['required_loader'],
        'textures'=>[{'material'=>'arbitrary','width'=>2,'height'=>1,'jpeg'=>ExactColorMapPixels.descriptor(File.join(session,'texture-0.base.jpg')),'base_frame'=>base,'target_frame'=>target}]}
      file=File.join(session,'report.json');File.write(file,JSON.generate(report))
      yield file,report,session
    end
  end
  def test_complete_host_frames_produce_exact_payload_without_changing_capture
    fixture do |file,original,session|
      before=File.binread(file)
      output=ExactColorMapOffline.convert(file)
      result=JSON.parse(File.read(output))
      assert_equal false,result['ready']
      assert_equal 'captured_pending_browser_verification',result['status']
      assert_equal Digest::SHA256.hexdigest(before),result['raw_capture_sha256']
      entry=result['textures'].first
      payload=File.binread(File.join(File.dirname(output),entry['file']))
      assert_equal [11,22,33,255,44,55,66,255].pack('C*'),BOMEngine::BOMCJpegColorMap.reconstruct(payload,[10,20,30,255,40,50,60,255].pack('C*'))
      assert_equal Digest::SHA256.hexdigest([11,22,33,255,44,55,66,255].pack('C*')),entry['expected_rgba_sha256']
      assert_equal before,File.binread(file)
    end
  end
  def test_changed_frame_incomplete_capture_and_escaped_path_cannot_produce_green_output
    ['hash','incomplete','escape','layout'].each do |kind|
      fixture do |file,report,session|
        case kind
        when 'hash' then File.binwrite(File.join(session,'texture-0.base.raw'),'tampered')
        when 'incomplete' then report['status']='running'
        when 'escape' then report['textures'][0]['target_frame']['file']='../outside.raw'
        when 'layout' then report['textures'][0]['target_frame']['channel_layout']='RGBA'
        end
        File.write(file,JSON.generate(report))
        assert_raises(ArgumentError) { ExactColorMapOffline.convert(file) }
        assert_empty Dir.glob(File.join(File.dirname(session),'offline-*'))
      end
    end
  end
  def test_canonical_rows_ignore_padding_and_preserve_transparency
    assert defined?(ExactColorMapOffline),'Offline processor missing'
    frame={'width'=>1,'height'=>2,'bits_per_pixel'=>32,'row_padding'=>1,'channel_layout'=>'BGRA','row_order'=>'top_down'}
    bytes=[3,2,1,128,99,6,5,4,0,99].pack('C*')
    assert_equal [1,2,3,128,4,5,6,0].pack('C*'),ExactColorMapOffline.canonical_rgba(bytes,frame)
  end
end
