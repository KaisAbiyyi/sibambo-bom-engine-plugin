require 'minitest/autorun'
require 'tmpdir'
require_relative '../bomc_extension'
require_relative '../bomc_jpeg_color_map'

class ExactJcmExportTest < Minitest::Test
  def graph
    base = [10,20,30,255,40,50,60,255].pack('C*')
    target = [11,22,33,255,44,55,66,255].pack('C*')
    jpeg = [255,216,255,192,0,17,8,0,1,0,2,3,1,17,0,2,17,0,3,17,0,255,218,0,12,3,1,0,2,0,3,0,0,63,0,1,255,217].pack('C*')
    bytes = BOMEngine::BOMCJpegColorMap.encode(jpeg: jpeg, base_rgba: base, target_rgba: target, width: 2, height: 1)
    evidence = {
      policy_revision: 'exact-jcm-1', selected: :jpeg_color_map_candidate, profile: :exact,
      alpha_preserved: true, selected_sha256: Digest::SHA256.hexdigest(bytes),
      base_pixel_sha256: Digest::SHA256.hexdigest(base), output_pixel_sha256: Digest::SHA256.hexdigest(target),
      normalized_jpeg_sha256: Digest::SHA256.hexdigest(jpeg), required_loader: 'bomc-next-jcm-v1',
      quality: { compatible: true, mean_squared_error: 0.0, max_channel_error: 0, alpha_preserved: true }
    }
    {
      materials: [{ id: 'm', texture: { bytes: bytes, filename: 'texture.jcm',
        image_width_px: 2, image_height_px: 1, encoding_evidence: evidence } }],
      definitions: [{ id: 'd', kind: 'root', node_ids: [] }],
      nodes: [{ id: 'root', kind: 'root', definition_id: 'd', transform_id: 0 }],
      transforms: [BOMEngine::BOMC::ModelAdapter::IDENTITY], meshes: [], tags: []
    }
  end

  def source_info_for(output_path, bytes)
    path = File.join(File.dirname(output_path), "source-#{bytes}.skp")
    File.binwrite(path, 'S' * bytes)
    BOMEngine::BOMCSizeGate.source_info(path)
  end

  def test_saved_skp_exact_jcm_requires_smaller_candidate
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'candidate.bomc')
      File.binwrite(file, 'keep-previous')
      assert_raises(BOMEngine::BOMCSizeGate::TargetNotMet) do
        BOMEngine::BOMCExtension.publish_graph(
          file, graph, profile: :exact, source_info: source_info_for(file, 1)
        )
      end
      assert_equal 'keep-previous', File.binread(file)
      assert_empty Dir.glob(File.join(dir, '*.part'))

      source = source_info_for(file, 10_000)
      result = BOMEngine::BOMCExtension.publish_graph(
        file, graph, profile: :exact, source_info: source
      )
      assert_equal true, result[:published]
      assert_equal File.size(file), result[:bytes]
      assert_equal 'bomc-next-jcm-v1', result[:required_loader]
      decoded = BOMEngine::BOMCDecoder.decode(File.binread(file))
      assert_equal :jpeg_color_map, decoded[:textures][0][:media_type]
      assert_equal source[:bytes], decoded.dig(:encoding_contract, :source_skp_bytes)
      assert_equal source[:bytes] - 1, decoded.dig(:encoding_contract, :target_bytes)
      assert_operator File.size(file), :<, source[:bytes], 'Saved-SKP Exact JCM must pass strict size gate'
    end
  end

  def test_exact_defaults_to_jcm_capability_but_can_be_explicitly_disabled
    Dir.mktmpdir do |dir|
      standard = File.join(dir, 'standard.bomc')
      assert BOMEngine::BOMCExtension.publish_graph(standard, graph, profile: :exact)[:published]

      disabled = File.join(dir, 'disabled.bomc')
      assert_raises(RuntimeError) do
        BOMEngine::BOMCExtension.publish_graph(
          disabled, graph, profile: :exact, allow_jpeg_color_map: false
        )
      end
      refute File.exist?(disabled)

      assert_raises(ArgumentError) do
        BOMEngine::BOMCExtension.publish_graph(
          File.join(dir, 'visual.bomc'), graph, profile: :visual, allow_jpeg_color_map: true
        )
      end
    end
  end

  def test_tampered_jcm_evidence_preserves_destination
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'candidate.bomc')
      File.binwrite(file, 'keep')
      bad = Marshal.load(Marshal.dump(graph))
      bad[:materials][0][:texture][:encoding_evidence][:selected_sha256] = '0' * 64
      assert_raises(BOMEngine::BOMCValidator::ProfileValidationError) do
        BOMEngine::BOMCExtension.publish_graph(file, bad, profile: :exact)
      end
      assert_equal 'keep', File.binread(file)
      assert_empty Dir.glob(File.join(dir, '*.part'))
    end
  end

  def test_explicit_strict_publication_helper_still_rechecks_source_identity
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source.skp')
      output = File.join(dir, 'candidate.bomc')
      File.binwrite(source, 'saved source bytes')
      source_info = BOMEngine::BOMCSizeGate.source_info(source)
      File.binwrite(output, 'keep')
      File.binwrite(source, 'changed after candidate was compiled')

      error = assert_raises(ArgumentError) do
        BOMEngine::BOMCExtension.publish_validated(
          candidate: 'valid-looking bytes', report: { passed: true }, output_path: output, source_info: source_info
        )
      end
      assert_match(/source changed/i, error.message)
      assert_equal 'keep', File.binread(output)
      assert_empty Dir.glob(File.join(dir, '*.part'))
    end
  end
end
