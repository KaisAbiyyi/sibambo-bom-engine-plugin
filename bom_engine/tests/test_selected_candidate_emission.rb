# frozen_string_literal: true
# Unit & regression tests for Track T6: Selected Candidate Emission & Producer Optimization

require 'test/unit'
require 'digest'
require_relative '../bomc_format'
require_relative '../bomc_codecs'
require_relative '../bomc_candidate'
require_relative '../bomc_budget_solver'
require_relative '../bomc_export_cache'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'

class TestSelectedCandidateEmission < Test::Unit::TestCase
  def sample_graph
    identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    positions = [
      0.0, 0.0, 0.0,
      1.0, 0.0, 0.0,
      1.0, 1.0, 0.0,
      0.0, 1.0, 0.0
    ]
    triangles = [0, 1, 2, 0, 2, 3]
    {
      format: { name: 'BOM Engine Canonical', version: '3.0.0' },
      source: { file_name: 'test.skp', model_name: 'Test Model', sha256: 'a' * 64 },
      coordinate_system: { units: 'm', handedness: 'right', up_axis: 'Z' },
      materials: [
        {
          id: 'mat_0', name: 'Material 0',
          color: { r: 200, g: 200, b: 200, a: 255 }, opacity: 1.0,
          texture: nil
        }
      ],
      tags: [],
      transforms: [identity],
      meshes: [
        {
          id: 'mesh_0',
          definition_id: 'def_0',
          positions_m: positions,
          faces: [
            {
              id: 'face_0',
              outer: [0, 1, 2, 3],
              holes: [],
              triangles: triangles,
              front_material_id: 'mat_0',
              back_material_id: nil,
              tag_id: nil,
              normal: [0.0, 0.0, 1.0],
              area_m2: 1.0,
              surface_hint: 'floor',
              hidden: false,
              semantic: { label: 'Floor', role: 'floor', source: 'instance_name', classification_policy: 'label_first' },
              uv: {
                front_outer: [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]],
                front_holes: []
              }
            }
          ],
          edges: []
        }
      ],
      definitions: [
        { id: 'def_root', name: 'Root', kind: 'model_definition', mesh_id: nil, node_ids: ['node_0'] },
        { id: 'def_0', name: 'Component 0', kind: 'component_definition', mesh_id: 'mesh_0', node_ids: [] }
      ],
      nodes: [
        { id: 'node_root', kind: 'root', name: 'Root', owner_definition_id: nil, definition_id: 'def_root', transform_id: 0, visible: true },
        { id: 'node_0', kind: 'component_instance', name: 'Instance 0', owner_definition_id: 'def_root', definition_id: 'def_0', transform_id: 0, visible: true }
      ]
    }
  end

  # Regression 1: Provide two candidate blocks for a group (e.g. Float64 vs Float32_Local for positions).
  # Prove that the selected candidate ID directly determines emitted codec and payload in final BOMC container.
  def test_selected_candidate_determines_emitted_codec_and_payload
    graph = sample_graph

    c_f64_bytes = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0].pack('E*')
    cand_f64 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :custom_pos_f64,
      domain: :positions,
      owner_id: 'mesh_0_positions',
      codec: BOMEngine::BOMC::PositionCodec::FLOAT64_ABSOLUTE,
      bytes: c_f64_bytes,
      params: {
        codec: BOMEngine::BOMC::PositionCodec::FLOAT64_ABSOLUTE,
        origin: [0.0, 0.0, 0.0],
        scale: [1.0, 1.0, 1.0],
        count: 4
      },
      stored_bytes_estimate: 240,
      distortion_score: 0.0,
      deterministic_rank: 1
    )

    c_f32_bytes = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0].pack('e*')
    cand_f32 = BOMEngine::BOMCCandidate::Candidate.new(
      id: :custom_pos_f32,
      domain: :positions,
      owner_id: 'mesh_0_positions',
      codec: BOMEngine::BOMC::PositionCodec::FLOAT32_LOCAL,
      bytes: c_f32_bytes,
      params: {
        codec: BOMEngine::BOMC::PositionCodec::FLOAT32_LOCAL,
        origin: [0.0, 0.0, 0.0],
        scale: [1.0, 1.0, 1.0],
        count: 4
      },
      stored_bytes_estimate: 64,
      distortion_score: 0.0001,
      deterministic_rank: 2
    )

    # Subtest 1A: Choose smaller candidate cand_f32
    pack_res_32 = BOMEngine::BOMCWriter.pack(
      graph,
      profile: :visual,
      candidate_groups: { 'mesh_0_positions' => [cand_f32, cand_f64] }
    )
    solver_selected_32 = pack_res_32[:solver_result][:selected_candidates]['mesh_0_positions']
    assert_equal :custom_pos_f32, solver_selected_32.id
    assert_equal BOMEngine::BOMC::PositionCodec::FLOAT32_LOCAL, solver_selected_32.codec

    parsed_32 = BOMEngine::BOMC::Container.parse(pack_res_32[:bytes])
    pos_sec_32 = parsed_32[:sections].find { |s| s[:type] == BOMEngine::BOMC::SECTION_POSITIONS }
    assert_not_nil pos_sec_32
    # First 12 bytes of position block: [version, codec, 0, 0, count, bytes_len]
    header_vals_32 = pos_sec_32[:bytes][0, 12].unpack('CCCCVV')
    assert_equal BOMEngine::BOMC::PositionCodec::FLOAT32_LOCAL, header_vals_32[1]
    # Payload starts after 12 bytes header + 24 bytes origin + 24 bytes scale = 60 bytes
    assert_equal c_f32_bytes, pos_sec_32[:bytes][60, header_vals_32[5]]

    # Subtest 1B: In Exact profile, highest-fidelity candidate (cand_f64) is chosen
    pack_res_64 = BOMEngine::BOMCWriter.pack(
      graph,
      profile: :exact,
      candidate_groups: { 'mesh_0_positions' => [cand_f32, cand_f64] }
    )
    solver_selected_64 = pack_res_64[:solver_result][:selected_candidates]['mesh_0_positions']
    assert_equal :custom_pos_f64, solver_selected_64.id
    assert_equal BOMEngine::BOMC::PositionCodec::FLOAT64_ABSOLUTE, solver_selected_64.codec

    parsed_64 = BOMEngine::BOMC::Container.parse(pack_res_64[:bytes])
    pos_sec_64 = parsed_64[:sections].find { |s| s[:type] == BOMEngine::BOMC::SECTION_POSITIONS }
    assert_not_nil pos_sec_64
    header_vals_64 = pos_sec_64[:bytes][0, 12].unpack('CCCCVV')
    assert_equal BOMEngine::BOMC::PositionCodec::FLOAT64_ABSOLUTE, header_vals_64[1]
    assert_equal c_f64_bytes, pos_sec_64[:bytes][60, header_vals_64[5]]
  end

  # Regression 2: Single-pass export caching (BOMCExportCache).
  # Verify hit/miss stats on repeated exports and 6-part key invalidation.
  def test_export_cache_single_pass_and_invalidation
    graph = sample_graph
    cache = BOMEngine::BOMCExportCache::Cache.new

    # First export: cold cache
    res1 = BOMEngine::BOMCWriter.pack(graph, profile: :visual, export_cache: cache)
    assert_operator cache.stats[:normalization_misses], :>, 0
    assert_equal 0, cache.stats[:normalization_hits]
    assert_operator cache.stats[:candidate_misses], :>, 0
    assert_equal 1, cache.stats[:preparation_misses]
    assert_equal 0, cache.stats[:preparation_hits]
    first_candidate_misses = cache.stats[:candidate_misses]

    # Second export: warm cache with same graph and profile
    res2 = BOMEngine::BOMCWriter.pack(graph, profile: :visual, export_cache: cache)
    assert_equal 1, cache.stats[:normalization_hits]
    assert_equal 1, cache.stats[:preparation_hits]
    assert_equal 0, cache.stats[:candidate_hits], 'prepared build bypasses lower-level candidate lookup on a warm export'
    assert_equal first_candidate_misses, cache.stats[:candidate_misses]
    assert_equal res1[:bytes], res2[:bytes]

    # 6-part key invalidation test
    base_params = {
      source_digest: 'source_abc123',
      profile: :visual,
      semantic_class: :structure,
      texture_digest: 'tex_def456',
      encoder_digest: 'enc_789',
      policy_revision: BOMEngine::BOMCExportCache::POLICY_REVISION
    }
    base_key = BOMEngine::BOMCExportCache::Cache.compute_key(**base_params)

    # 1. Mutate source_digest
    key1 = BOMEngine::BOMCExportCache::Cache.compute_key(**base_params.merge(source_digest: 'source_different'))
    assert_not_equal base_key, key1

    # 2. Mutate profile
    key2 = BOMEngine::BOMCExportCache::Cache.compute_key(**base_params.merge(profile: :research))
    assert_not_equal base_key, key2

    # 3. Mutate semantic_class
    key3 = BOMEngine::BOMCExportCache::Cache.compute_key(**base_params.merge(semantic_class: :ornament))
    assert_not_equal base_key, key3

    # 4. Mutate texture_digest
    key4 = BOMEngine::BOMCExportCache::Cache.compute_key(**base_params.merge(texture_digest: 'tex_mutated'))
    assert_not_equal base_key, key4

    # 5. Mutate encoder_digest
    key5 = BOMEngine::BOMCExportCache::Cache.compute_key(**base_params.merge(encoder_digest: 'enc_mutated'))
    assert_not_equal base_key, key5

    # 6. Mutate policy_revision
    key6 = BOMEngine::BOMCExportCache::Cache.compute_key(**base_params.merge(policy_revision: '2026.09.09.2'))
    assert_not_equal base_key, key6
  end

  def test_unsaved_fixture_digest_streams_without_graph_inspect_materialization
    graph = sample_graph
    graph[:source].delete(:sha256)
    graph.define_singleton_method(:inspect) { raise 'graph.inspect must not be used for source identity' }
    result = BOMEngine::BOMCWriter.pack(graph, profile: :visual)
    digest = result.fetch(:prepared_candidates).source_digest
    assert_match(/\A[0-9a-f]{64}\z/, digest)
  end

  # Regression 3: Soft Visual target bounded by actual frontiers with diagnostic reason on fallback <90%.
  def test_visual_soft_target_bounded_frontiers_and_diagnostic_reason
    # 1000 bytes source SKP:
    # hard budget = 900 bytes (90%)
    # preferred target = 600 bytes (60%)
    c_high = BOMEngine::BOMCCandidate::Candidate.new(
      id: :cand_high,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 800,
      distortion_score: 0.01,
      deterministic_rank: 1
    )
    c_mid = BOMEngine::BOMCCandidate::Candidate.new(
      id: :cand_mid,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 700,
      distortion_score: 0.05,
      deterministic_rank: 2
    )

    # Subtest 3A: Frontier exhausted at 700 bytes (above 600 bytes preferred, but within 900 bytes hard)
    res_bounded = BOMEngine::BOMCBudgetSolver.solve(
      profile: :visual,
      source_skp_bytes: 1000,
      candidate_groups: { mesh_0: [c_high, c_mid] }
    )
    assert_equal :budget_passed, res_bounded[:status]
    assert_equal false, res_bounded[:preferred_target_achieved]
    assert_not_nil res_bounded[:diagnostic_reason]
    assert_match(/Preferred target of 60% \(600 bytes\) could not be reached/, res_bounded[:diagnostic_reason])
    assert_match(/candidate frontier exhausted within tolerance/, res_bounded[:diagnostic_reason])
    assert_equal :cand_mid, res_bounded[:selected_candidates][:mesh_0].id

    # Subtest 3B: Lower candidate available that achieves preferred 60% target
    c_low = BOMEngine::BOMCCandidate::Candidate.new(
      id: :cand_low,
      domain: :positions,
      owner_id: :mesh_0,
      stored_bytes_estimate: 550,
      distortion_score: 0.10,
      deterministic_rank: 3
    )
    res_achieved = BOMEngine::BOMCBudgetSolver.solve(
      profile: :visual,
      source_skp_bytes: 1000,
      candidate_groups: { mesh_0: [c_high, c_mid, c_low] }
    )
    assert_equal :budget_passed, res_achieved[:status]
    assert_equal true, res_achieved[:preferred_target_achieved]
    assert_nil res_achieved[:diagnostic_reason]
    assert_equal :cand_low, res_achieved[:selected_candidates][:mesh_0].id
  end

  # Regression 4: Single-pass pack_with_metrics without self-inflate.
  def test_single_pass_pack_with_metrics_no_self_inflate
    sections = [
      { type: BOMEngine::BOMC::SECTION_MODEL, count: 1, bytes: "MODEL_DATA".b, compress: true },
      { type: BOMEngine::BOMC::SECTION_STRINGS, count: 2, bytes: "STRINGS_DATA".b, compress: true }
    ]

    pack_res = BOMEngine::BOMC::Container.pack_with_metrics(sections)
    assert_kind_of Hash, pack_res
    assert_not_nil pack_res[:bytes]
    assert_not_nil pack_res[:section_metrics]
    assert_not_nil pack_res[:header_metrics]

    # Verify Container.pack is a preserved wrapper returning exact same bytes
    pack_bytes = BOMEngine::BOMC::Container.pack(sections)
    assert_equal pack_res[:bytes], pack_bytes

    # Parse container once to compare against the single-pass metrics
    parsed = BOMEngine::BOMC::Container.parse(pack_res[:bytes])
    assert_equal parsed[:sections].length, pack_res[:section_metrics].length

    pack_res[:section_metrics].each_with_index do |metric, idx|
      parsed_sec = parsed[:sections][idx]
      assert_equal metric[:type], parsed_sec[:type]
      assert_equal metric[:stored_size], parsed_sec[:stored_size]
      assert_equal metric[:raw_size], parsed_sec[:raw_size]
      assert_equal metric[:crc32], parsed_sec[:crc32]
      assert_equal metric[:codec], parsed_sec[:codec]
    end

    # Test BOMCWriter build uses single-pass metrics directly
    writer_res = BOMEngine::BOMCWriter.pack(sample_graph, profile: :visual)
    sec_metrics = writer_res.dig(:metrics, :sections)
    assert_not_nil sec_metrics
    assert_kind_of Hash, sec_metrics
    assert sec_metrics.key?(:model)
    assert sec_metrics.key?(:strings)
  end

  # Regression 5: PreparedCandidates record and immutable Candidate.
  def test_prepared_candidates_and_immutability
    cand = BOMEngine::BOMCCandidate::Candidate.new(
      id: :cand_test,
      domain: :positions,
      owner_id: :mesh_0,
      codec: 1,
      bytes: "POS_BYTES".b,
      stored_bytes_estimate: 100,
      distortion_score: 0.05
    )
    assert cand.frozen?

    prepared = BOMEngine::BOMCCandidate::PreparedCandidates.new(
      source_digest: 'digest_123',
      profile: :visual,
      policy_revision: '2026.09.08.1',
      candidate_groups: { mesh_0: [cand] },
      fixed_sections: [:model, :strings]
    )
    assert_equal 'digest_123', prepared.source_digest
    assert_equal :visual, prepared.profile
    assert_equal '2026.09.08.1', prepared.policy_revision
    assert_equal 1, prepared.candidate_groups[:mesh_0].length
    assert_equal :cand_test, prepared.candidate_groups[:mesh_0].first.id
  end
end
