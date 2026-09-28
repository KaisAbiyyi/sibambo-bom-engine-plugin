require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'digest'
require 'fileutils'
require_relative '../bomc_jpeg_color_map'
require_relative '../bomc_texture_optimizer'
require_relative '../bomc_extension'
require_relative '../material_extractor'
require_relative '../bomc_prepared_color_maps' if File.file?(File.expand_path('../bomc_prepared_color_maps.rb', __dir__))

class PreparedColorMapsTest < Minitest::Test
  Frame = Struct.new(:width, :height, :bits_per_pixel, :row_padding, :data)

  def fixture
    Dir.mktmpdir do |root|
      host_dir = File.join(root, 'pixels-test')
      offline_dir = File.join(root, 'offline-test')
      FileUtils.mkdir_p(host_dir)
      FileUtils.mkdir_p(offline_dir)
      jpeg = [255,216,255,192,0,17,8,0,1,0,2,3,1,17,0,2,17,0,3,17,0,255,218,0,12,3,1,0,2,0,3,0,0,63,0,1,255,217].pack('C*')
      base = [10,20,30,255,40,50,60,255].pack('C*')
      target = [11,22,33,255,44,55,66,255].pack('C*')
      raw_target = [33,22,11,255,66,55,44,255].pack('C*')
      payload = BOMEngine::BOMCJpegColorMap.encode(jpeg: jpeg, base_rgba: base, target_rgba: target, width: 2, height: 1)
      native_path = File.join(host_dir, 'texture-0.native.jpg')
      target_path = File.join(host_dir, 'texture-0.target.raw')
      payload_path = File.join(offline_dir, 'texture-0.jcm')
      File.binwrite(native_path, jpeg)
      File.binwrite(target_path, raw_target)
      File.binwrite(payload_path, payload)
      host = {
        'schema' => 'exact-color-map-host-pixels-v1', 'status' => 'captured_pending_offline_verification', 'ready' => false,
        'source_tree_sha256' => 'a' * 64, 'required_loader' => 'bomc-next-jcm-v1',
        'textures' => [{
          'width' => 2, 'height' => 1,
          'native_jpeg' => {'file' => 'texture-0.native.jpg', 'bytes' => jpeg.bytesize, 'sha256' => Digest::SHA256.hexdigest(jpeg)},
          'target_frame' => {'file' => 'texture-0.target.raw', 'bytes' => raw_target.bytesize,
            'sha256' => Digest::SHA256.hexdigest(raw_target), 'width' => 2, 'height' => 1,
            'bits_per_pixel' => 32, 'row_padding' => 0, 'channel_layout' => 'BGRA', 'row_order' => 'top_down'}
        }]
      }
      host_report = File.join(host_dir, 'report.json')
      File.write(host_report, JSON.generate(host))
      offline = {
        'schema' => 'exact-color-map-offline-v1', 'status' => 'captured_pending_browser_verification', 'ready' => false,
        'required_loader' => 'bomc-next-jcm-v1', 'source_tree_sha256' => 'a' * 64,
        'raw_capture_file' => 'pixels-test/report.json', 'raw_capture_sha256' => Digest::SHA256.file(host_report).hexdigest,
        'textures' => [{'file' => 'texture-0.jcm', 'width' => 2, 'height' => 1, 'bytes' => payload.bytesize,
          'sha256' => Digest::SHA256.hexdigest(payload), 'base_rgba_sha256' => Digest::SHA256.hexdigest(base),
          'expected_rgba_sha256' => Digest::SHA256.hexdigest(target)}]
      }
      offline_report = File.join(offline_dir, 'report.json')
      File.write(offline_report, JSON.generate(offline))
      browser = {'schema' => 'exact-color-map-browser-evidence-v1', 'status' => 'sample_pixels_verified',
        'evidence_kind' => 'runtime_capture', 'ready' => false, 'capture_report_sha256' => Digest::SHA256.file(offline_report).hexdigest,
        'source_tree_sha256' => 'a' * 64,
        'textures' => [{'file' => 'texture-0.jcm', 'sha256' => Digest::SHA256.hexdigest(payload), 'status' => 'verified',
          'width' => 2, 'height' => 1, 'rgba_sha256' => Digest::SHA256.hexdigest(target)}]}
      browser_report = File.join(root, 'browser-report.json')
      File.write(browser_report, JSON.generate(browser))
      yield host_report, offline_report, browser_report, jpeg, raw_target, payload
    end
  end

  def test_verified_live_pixels_use_prepared_payload_without_png_or_webp_work
    fixture do |_host, offline, browser, jpeg, raw_target, payload|
      prepared = BOMEngine::BOMCPreparedColorMaps.load(offline_report: offline, browser_report: browser)
      texture = Object.new
      texture.define_singleton_method(:image_width) { 2 }
      texture.define_singleton_method(:image_height) { 1 }
      texture.define_singleton_method(:image_rep) { |_colorized| Frame.new(2, 1, 32, 0, raw_target) }
      texture.define_singleton_method(:write) do |path, colorized|
        raise 'PNG staging occurred' if colorized
        File.binwrite(path, jpeg)
        true
      end
      Dir.mktmpdir do |dir|
        budget = {remaining_pixels: 2, hashes: {}}
        result = BOMEngine::BOMCTextureOptimizer.stage(texture: texture, directory: dir, basename: 'any-name',
          source_path: 'embedded.jpg', profile: :exact, allow_jpeg_color_map: true,
          color_map_budget: budget, prepared_color_maps: prepared)
        assert_equal payload, File.binread(result[:path])
        assert_equal :jpeg_color_map_candidate, result.dig(:evidence, :selected)
        assert_equal 0, budget[:remaining_pixels]
        assert_empty Dir.glob(File.join(dir, '*.png'))
      end
    end
  end

  def test_changed_host_pixels_or_jpeg_cannot_reuse_prepared_payload
    fixture do |_host, offline, browser, jpeg, raw_target, _payload|
      prepared = BOMEngine::BOMCPreparedColorMaps.load(offline_report: offline, browser_report: browser)
      [raw_target.byteslice(0, 7) + "\0", raw_target].each_with_index do |pixels, index|
        texture = Object.new
        texture.define_singleton_method(:image_width) { 2 }
        texture.define_singleton_method(:image_height) { 1 }
        texture.define_singleton_method(:image_rep) { |_| Frame.new(2, 1, 32, 0, pixels) }
        texture.define_singleton_method(:write) { |path, _| File.binwrite(path, index == 0 ? jpeg : jpeg + 'changed'); true }
        Dir.mktmpdir do |dir|
          assert_nil prepared.stage(texture: texture, directory: dir, basename: "changed-#{index}",
            source_path: 'embedded.jpg', budget: {remaining_pixels: 2, hashes: {}})
          assert_empty Dir.glob(File.join(dir, '*.jcm'))
        end
      end
    end
  end

  def test_same_raw_bytes_with_changed_frame_shape_cannot_reuse_payload
    fixture do |_host, offline, browser, jpeg, raw_target, _payload|
      prepared = BOMEngine::BOMCPreparedColorMaps.load(offline_report: offline, browser_report: browser)
      texture = Object.new
      texture.define_singleton_method(:image_width) { 2 }
      texture.define_singleton_method(:image_height) { 1 }
      texture.define_singleton_method(:image_rep) { |_| Frame.new(1, 2, 32, 0, raw_target) }
      texture.define_singleton_method(:write) { |path, _| File.binwrite(path, jpeg); true }
      Dir.mktmpdir do |dir|
        assert_nil prepared.stage(texture: texture, directory: dir, basename: 'shape-mismatch',
          source_path: 'embedded.jpg', budget: {remaining_pixels: 2, hashes: {}})
        assert_empty Dir.glob(File.join(dir, '*.jcm'))
      end
    end
  end

  def test_altered_or_unverified_evidence_cannot_be_loaded
    fixture do |_host, offline, browser, _jpeg, _raw_target, _payload|
      report = JSON.parse(File.read(browser))
      report['textures'][0]['status'] = 'failed'
      File.write(browser, JSON.generate(report))
      assert_raises(ArgumentError) { BOMEngine::BOMCPreparedColorMaps.load(offline_report: offline, browser_report: browser) }
    end
    fixture do |_host, offline, browser, _jpeg, _raw_target, _payload|
      File.binwrite(File.join(File.dirname(offline), 'texture-0.jcm'), 'tampered')
      assert_raises(ArgumentError) { BOMEngine::BOMCPreparedColorMaps.load(offline_report: offline, browser_report: browser) }
    end
  end

  def test_prepared_texture_reaches_material_snapshot_and_exact_publication
    fixture do |_host, offline, browser, jpeg, raw_target, payload|
      prepared = BOMEngine::BOMCPreparedColorMaps.load(offline_report: offline, browser_report: browser)
      texture = Object.new
      texture.define_singleton_method(:filename) { 'embedded.jpg' }
      texture.define_singleton_method(:image_width) { 2 }
      texture.define_singleton_method(:image_height) { 1 }
      texture.define_singleton_method(:width) { 2.0 }
      texture.define_singleton_method(:height) { 1.0 }
      texture.define_singleton_method(:image_rep) { |_| Frame.new(2, 1, 32, 0, raw_target) }
      texture.define_singleton_method(:write) do |path, colorized|
        raise 'PNG staging occurred' if colorized
        File.binwrite(path, jpeg)
        true
      end
      color = Struct.new(:red, :green, :blue, :alpha).new(255, 255, 255, 255)
      material = Struct.new(:name, :display_name, :color, :alpha, :materialType, :texture).new('arbitrary', 'arbitrary', color, 1, 1, texture)
      model = Struct.new(:materials, :entities).new([material], [])
      Dir.mktmpdir do |dir|
        extracted = BOMEngine::MaterialExtractor.extract(model, nil, dir, optimize_textures: true,
          profile: :exact, allow_jpeg_color_map: true, prepared_color_maps: prepared)
        staged = extracted.fetch(0).fetch(:texture)
        assert_equal payload, File.binread(File.join(dir, staged.fetch(:filename)))
        assert_equal :jpeg_color_map_candidate, staged.dig(:staging_evidence, :selected)
        graph = {
          materials: [{id: 'm', name: 'arbitrary', texture: {image_width_px: 2, image_height_px: 1}}],
          definitions: [{id: 'd', kind: 'root', node_ids: []}],
          nodes: [{id: 'root', kind: 'root', definition_id: 'd', transform_id: 0}],
          transforms: [BOMEngine::BOMC::ModelAdapter::IDENTITY], meshes: [], tags: []
        }
        BOMEngine::BOMCExtension.send(:attach_staged_textures, graph, extracted, dir, profile: :exact)
        output = File.join(dir, 'candidate.bomc')
        source_path = File.join(dir, 'source.skp')
        File.binwrite(source_path, 'S' * 1_000_000)
        result = BOMEngine::BOMCExtension.publish_graph(output, graph, profile: :exact,
          source_info: BOMEngine::BOMCSizeGate.source_info(source_path), allow_jpeg_color_map: true)
        assert_equal true, result[:published]
        assert_equal 'bomc-next-jcm-v1', result[:required_loader]
        FileUtils.mkdir_p(File.join(dir, 'snapshot'))
        snapshot = BOMEngine::BOMCExtension.send(:snapshot_model, model, File.join(dir, 'snapshot'),
          ->(**_) {}, profile: :exact, allow_jpeg_color_map: true, prepared_color_maps: prepared)
        assert_equal :jpeg_color_map_candidate, snapshot.dig(:materials, 0, :texture, :encoding_evidence, :staging, :selected)
        context = BOMEngine::BOMCExtension.send(:export_context, File.join(dir, 'export.bomc'), ->(_event) {},
          profile: :exact, allow_jpeg_color_map: true, prepared_color_maps: prepared)
        begin
          from_export = context.fetch(:snapshot).call(model, ->(**_) {})
          assert_equal :jpeg_color_map_candidate,
            from_export.dig(:materials, 0, :texture, :encoding_evidence, :staging, :selected)
        ensure
          context.fetch(:cleanup).call
        end
      end
    end
  end
end
