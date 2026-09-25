require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../../tools/history/exact_color_map_capture'
require_relative '../../tools/history/build_exact_color_map_preview' if File.file?(File.expand_path('../../tools/history/build_exact_color_map_preview.rb',__dir__))

class ExactColorMapPreviewTest < Minitest::Test
  def test_progress_updates_are_rate_limited_but_cancellation_is_checked_every_time
    assert_respond_to ExactColorMapPreview,:progress_checkpoint
    now=0.0
    messages=[]
    checkpoint=ExactColorMapPreview.progress_checkpoint(clock: -> { now }, cancelled: -> { false },
      publish: ->(done,total) { messages << [done,total] })
    1000.times { |i| checkpoint.call(i,1000) }
    assert_equal [[0,1000]],messages
    now=0.3
    checkpoint.call(1000,1000)
    assert_equal [[0,1000],[1000,1000]],messages
    cancelled=false
    checkpoint=ExactColorMapPreview.progress_checkpoint(clock: -> { now }, cancelled: -> { cancelled },publish: ->(*) {})
    checkpoint.call(0,1000)
    cancelled=true
    assert_raises(ExactColorMapPreview::Cancelled) { checkpoint.call(1,1000) }
  end
  def test_isolated_snapshot_does_not_install_or_overwrite_and_pins_runtime_bytes
    assert defined?(ExactColorMapPreviewBuilder), 'Preview builder missing'
    Dir.mktmpdir do |root|
      out=File.join(root,'kit')
      manifest=ExactColorMapPreviewBuilder.build(output:out)
      assert_equal false,manifest['ready']
      assert_equal 'bomc-next-jcm-v1',manifest['required_loader']
      assert File.file?(File.join(out,'run.rb'))
      assert File.file?(File.join(out,'run_pixels.rb')),'Lean capture entry missing'
      manifest.fetch('files').each { |rel,sha| assert_equal sha,Digest::SHA256.file(File.join(out,rel)).hexdigest }
      assert_raises(ArgumentError) { ExactColorMapPreviewBuilder.build(output:out) }
      result=IO.popen([RbConfig.ruby,'-e',"require #{File.join(out,'run.rb').inspect}; puts ExactColorMapPreview.respond_to?(:start)"]){|io|io.read}
      assert $?.success?,result
      assert_includes result,'true'
      result=IO.popen([RbConfig.ruby,'-e',"require #{File.join(out,'run_pixels.rb').inspect}; puts ExactColorMapPixels.respond_to?(:start)"]){|io|io.read}
      assert $?.success?,result
      assert_includes result,'true'
    end
  end
end
