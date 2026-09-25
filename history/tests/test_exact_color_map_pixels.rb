require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'digest'
require_relative '../../bom_engine/bomc_jpeg_color_map'
require_relative '../../tools/history/build_exact_color_map_preview'
path=File.expand_path('../../tools/history/exact_color_map_pixels.rb',__dir__)
require path if File.file?(path)

class ExactColorMapPixelsTest < Minitest::Test
  Frame=Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data)
  JPEG=[255,216,255,192,0,17,8,0,1,0,2,3,1,17,0,2,17,0,3,17,0,255,218,0,12,3,1,0,2,0,3,0,0,63,0,1,255,217].pack('C*')
  def capture(dir, target: Frame.new(2,1,32,0,[33,22,11,255,66,55,44,255].pack('C*')), &checkpoint)
    assert defined?(ExactColorMapPixels),'Lean capture missing'
    texture=Object.new
    texture.define_singleton_method(:image_width) { 2 }
    texture.define_singleton_method(:image_height) { 1 }
    texture.define_singleton_method(:write) do |file,colorized|
      raise 'Must not encode PNG or colorized JPEG' if colorized || !file.end_with?('.jpg')
      File.binwrite(file,JPEG);true
    end
    texture.define_singleton_method(:image_rep) { |colorized| raise unless colorized;target }
    base=Frame.new(2,1,24,2,[30,20,10,60,50,40,99,99].pack('C*'))
    ExactColorMapPixels.capture_texture(texture,dir,0,codec:BOMEngine::BOMCJpegColorMap,loader: ->(_) { base },&checkpoint)
  end
  def test_capture_preserves_host_frames_without_png_webp_or_geometry
    Dir.mktmpdir do |dir|
      phases=[]
      entry=capture(dir) { |phase| phases << phase }
      assert_equal [30,20,10,60,50,40,99,99].pack('C*'),File.binread(File.join(dir,entry['base_frame']['file']))
      assert_equal [33,22,11,255,66,55,44,255].pack('C*'),File.binread(File.join(dir,entry['target_frame']['file']))
      assert_equal 'BGR',entry['base_frame']['channel_layout']
      assert_equal 2,entry['base_frame']['row_padding']
      %w[jpeg base_frame target_frame].each do |kind|
        data=File.binread(File.join(dir,entry[kind]['file']))
        assert_equal Digest::SHA256.hexdigest(data),entry[kind]['sha256']
        assert_equal data.bytesize,entry[kind]['bytes']
      end
      assert_operator phases.uniq.length,:>=,4
      assert_empty Dir.glob(File.join(dir,'*.png'))
      assert_empty Dir.glob(File.join(dir,'*.webp'))
    end
  end
  def test_invalid_raw_layout_never_publishes_a_completed_frame
    Dir.mktmpdir do |dir|
      assert defined?(ExactColorMapPixels),'Lean capture missing'
      assert_raises(ArgumentError) { capture(dir,target:Frame.new(2,1,32,0,'short')) }
      refute File.exist?(File.join(dir,'texture-0.target.raw'))
    end
  end
  def test_cancel_and_existing_output_are_not_swallowed_or_overwritten
    Dir.mktmpdir do |dir|
      assert defined?(ExactColorMapPixels),'Lean capture missing'
      error=Class.new(StandardError)
      assert_raises(error) { capture(dir) { raise error } }
      File.binwrite(File.join(dir,'texture-0.native.jpg'),'keep')
      assert_raises(ArgumentError) { capture(dir) }
      assert_equal 'keep',File.binread(File.join(dir,'texture-0.native.jpg'))
    end
  end
  def with_host
    Dir.mktmpdir do |root|
      kit=File.join(root,'kit');ExactColorMapPreviewBuilder.build(output:kit)
      model_file=File.join(root,'model.skp');File.binwrite(model_file,'saved model')
      target=Frame.new(2,1,32,0,[33,22,11,255,66,55,44,255].pack('C*'))
      texture=Struct.new(:filename,:image_width,:image_height).new('embedded.jpg',2,1)
      texture.define_singleton_method(:write) { |file,colorized| raise if colorized;File.binwrite(file,JPEG);true }
      texture.define_singleton_method(:image_rep) { |colorized| raise unless colorized;target }
      material=Struct.new(:name,:texture).new('any material',texture)
      model=Struct.new(:path,:materials,:modified).new(model_file,[material],false)
      model.define_singleton_method(:modified?) { modified }
      queue=[];messages=[]
      host=Module.new;ui=Module.new
      host.define_singleton_method(:active_model) { model }
      host.define_singleton_method(:version) { 'test-runtime' }
      host.define_singleton_method(:set_status_text) { |_| }
      loader=Class.new
      loader.define_singleton_method(:new) { |_| Frame.new(2,1,24,2,[30,20,10,60,50,40,99,99].pack('C*')) }
      host.const_set(:ImageRep,loader)
      ui.define_singleton_method(:start_timer) { |_,_,&block| queue << block }
      ui.define_singleton_method(:messagebox) { |message| messages << message }
      Object.const_set(:Sketchup,host);Object.const_set(:UI,ui)
      ExactColorMapPixels.configure(kit,BOMEngine)
      yield kit,model,queue,messages
    ensure
      Object.send(:remove_const,:Sketchup) if Object.const_defined?(:Sketchup)
      Object.send(:remove_const,:UI) if Object.const_defined?(:UI)
    end
  end
  def test_runtime_yields_between_phases_and_completes_only_after_all_frames
    with_host do |kit,model,queue,messages|
      session=ExactColorMapPixels.start(min_pixels:1)
      queue.shift.call
      first_report=JSON.parse(File.read(File.join(session,'report.json')))
      assert_equal 'running',first_report['status'],first_report.inspect
      assert_empty Dir.glob(File.join(session,'*.raw'))
      ticks=1
      until queue.empty?
        queue.shift.call;ticks+=1;raise 'timer loop' if ticks>30
      end
      report=JSON.parse(File.read(File.join(session,'report.json')))
      assert_equal 'captured_pending_offline_verification',report['status']
      assert_equal false,report['ready']
      assert_equal 1,report['textures'].length
      assert_operator ticks,:>=,6
      assert_equal 1,messages.length
    end
  end
  def test_runtime_cancel_or_model_change_cannot_complete
    [:cancel,:changed].each do |action|
      with_host do |kit,model,queue,messages|
        session=ExactColorMapPixels.start(min_pixels:1)
        queue.shift.call
        action==:cancel ? ExactColorMapPixels.cancel : model.modified=true
        queue.shift.call until queue.empty?
        report=JSON.parse(File.read(File.join(session,'report.json')))
        assert_equal action==:cancel ? 'cancelled' : 'failed',report['status'],report.inspect
        assert_empty report['textures']
        assert_equal false,report['ready']
      end
    end
  end
end
