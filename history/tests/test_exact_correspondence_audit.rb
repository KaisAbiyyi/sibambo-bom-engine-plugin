# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'digest'
require 'tmpdir'
require_relative '../../tools/history/capture_fidelity_audit'
require_relative '../../tools/history/adaptive_preview/capture'
require_relative '../../bom_engine/bomc_writer'
require_relative '../../bom_engine/bomc_decoder'

class ExactCorrespondenceAuditTest < Minitest::Test
  def setup
    @folder = Dir.mktmpdir('exact-correspondence-audit-')
    @native = File.join(@folder, 'native-reference.jsonl')
    @bomc = File.join(@folder, 'exact.bomc')
    @sidecar = File.join(@folder, 'source-correspondence-exact.json')
    File.binwrite(@bomc, 'exact fixture')
    @source_sha = 'a' * 64
    @native_rows = [
      { 'kind' => 'header', 'schema_version' => 't7-native-reference-raw-v2' },
      { 'kind' => 'definition', 'id' => 'def-1', 'name' => 'Unit' },
      native_face('face-1', 0, [[0, 1, 2], [2, 1, 2], [0, 2, 2]]),
      native_face('face-2', 0, [[4, 1, 2], [6, 1, 2], [4, 2, 2]]),
      { 'kind' => 'instance', 'type' => 'ComponentInstance', 'id' => 'inst-1', 'owner' => 'root', 'definition' => 'def-1',
        'transform' => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 10, 20, 30, 1], 'hidden' => true },
      { 'kind' => 'footer', 'status' => 'complete' }
    ]
    @decoded = {
      format: { profile: :production }, encoding_contract: { profile: :exact },
      definitions: [{ kind: 'model_definition', mesh: 0 }, { kind: 'component_definition', mesh: nil }],
      meshes: [{ definition: 0, positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
                 faces: [output_face(0, [0, 1, 2]), output_face(2, [0, 1, 2])] }],
      instances: [{ kind: 'root', transform: 0, definition: 0, visible: true },
                  { kind: 'component_instance', owner_definition: 0, transform: 1, definition: 1, visible: false }],
      transforms: [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                   [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.254, 0.508, 0.762, 1]]
    }
    @mapping = {
      'schema' => 'bomc-source-correspondence-v1', 'ready' => false,
      'source_sha256' => @source_sha, 'bomc_sha256' => Digest::SHA256.file(@bomc).hexdigest,
      'definitions' => [{ 'index' => 0, 'source_id' => 'root', 'kind' => 'root' },
                        { 'index' => 1, 'source_id' => 'def-1', 'kind' => 'component_definition' }],
      'instances' => [{ 'index' => 0, 'source_id' => nil, 'kind' => 'root' },
                      { 'index' => 1, 'source_id' => 'inst-1', 'kind' => 'component_instance' }],
      'faces' => [{ 'mesh' => 0, 'face' => 0, 'definition' => 0, 'source_id' => 'face-1' },
                  { 'mesh' => 0, 'face' => 1, 'definition' => 0, 'source_id' => 'face-2' }]
    }
    write_evidence
  end

  def teardown
    FileUtils.remove_entry(@folder)
  end

  def native_face(id, offset, uvq)
    { 'kind' => 'face', 'id' => id, 'owner' => 'root', 'normal' => [0, 0, 1], 'hidden' => false,
      'loops' => [{ 'outer' => true, 'points_m' => [[offset, 0, 0], [offset + 1, 0, 0], [offset, 1, 0]] }],
      'loop_uvq' => { 'status' => 'measured', 'front_outer' => uvq, 'front_holes' => [] } }
  end

  def output_face(offset, indices)
    { outer: indices, holes: [], normal: [0, 0, 1], has_front_uv: true, has_back_uv: false,
      uv: { front_outer: [[offset, 0.5], [offset + 1, 0.5], [offset, 1]], front_holes: [] }, hidden: false }
  end

  def write_evidence
    File.write(@native, @native_rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
    File.write(@sidecar, JSON.generate(@mapping))
    status = { 'status' => 'captured_pending_certification', 'ready' => false,
      'source' => { 'sha256' => @source_sha },
      'reference' => { 'sha256' => Digest::SHA256.file(@native).hexdigest },
      'profiles' => { 'exact' => { 'export_status' => 'success', 'source_model_sha256' => @source_sha,
        'bomc_sha256' => Digest::SHA256.file(@bomc).hexdigest,
        'source_correspondence' => { 'path' => @sidecar,
          'sha256' => Digest::SHA256.file(@sidecar).hexdigest,
          'schema' => 'bomc-source-correspondence-v1' } } } }
    File.write(File.join(@folder, 'session-status.json'), JSON.generate(status))
  end

  def audit
    CaptureFidelityAudit.compare_exact_correspondence(native_path: @native, bomc_path: @bomc,
      correspondence_path: @sidecar, decoded: @decoded)
  end

  def test_valid_source_bound_uv_and_instance_transform
    result = audit
    assert_equal 'verified', result.dig(:correspondence, :status)
    assert_equal 'matched', result.dig(:uv_values, :status)
    assert_equal 12, result.dig(:uv_values, :compared_scalars)
    assert_equal 'matched', result.dig(:instance_transforms, :status)
    assert_equal 16, result.dig(:instance_transforms, :compared_scalars)
    assert_equal false, result[:ready]
  end

  def test_actual_exact_wire_bytes_match_native_uvq_and_instance_matrix
    texture = "\x89PNG\r\n\x1a\nfixture".b
    @native_rows.insert(2, { 'kind' => 'material', 'id' => 'mat-pid',
      'name' => 'Texture', 'color' => [0, 0, 0, 255], 'alpha' => 1.0,
      'texture' => { 'filename' => 'fixture.png' } })
    @native_rows.select { |row| row['kind'] == 'face' }.each { |row| row['front_material'] = 'mat-pid' }
    @native_rows.find { |row| row['id'] == 'face-2' }['hidden'] = true
    graph = {
      source: { file_name: 'fixture.skp', model_name: 'Fixture' },
      materials: [{ id: 'mat', name: 'Texture', texture: {
        bytes: texture, filename: 'fixture.png', image_width_px: 2, image_height_px: 2
      } }], tags: [],
      transforms: [
        [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
        [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.254, 0.508, 0.762, 1]
      ],
      meshes: [{ id: 'root-mesh', definition_id: 'root-def',
        positions_m: [0, 0, 0, 1, 0, 0, 0, 1, 0],
        faces: [
          { id: 'first', source_identity: { persistent_id: 'face-1' },
            outer: [0, 1, 2], triangles: [0, 1, 2], front_material_id: 'mat',
            normal: [0, 0, 1], area_m2: 0.5, hidden: false,
            uv: { front_outer: [[0, 0.5], [1, 0.5], [0, 1]], front_holes: [] } },
          { id: 'second', source_identity: { persistent_id: 'face-2' },
            outer: [0, 1, 2], triangles: [0, 1, 2], front_material_id: 'mat',
            normal: [0, 0, 1], area_m2: 0.5, hidden: true,
            uv: { front_outer: [[2, 0.5], [3, 0.5], [2, 1]], front_holes: [] } }
        ], edges: [] }],
      definitions: [
        { id: 'root-def', kind: 'root', name: 'Root', mesh_id: 'root-mesh', node_ids: ['inst'] },
        { id: 'child-def', kind: 'component_definition', name: 'Unit',
          mesh_id: nil, node_ids: [], source_identity: { persistent_id: 'def-1' } }
      ],
      nodes: [
        { id: 'root', kind: 'root', name: 'Root', definition_id: 'root-def', transform_id: 0 },
        { id: 'inst', kind: 'component_instance', name: 'Unit 1',
          owner_definition_id: 'root-def', definition_id: 'child-def', transform_id: 1,
          visible: false, source_identity: { persistent_id: 'inst-1' } }
      ]
    }
    File.binwrite(@bomc, BOMEngine::BOMCWriter.pack(graph, profile: :exact).fetch(:bytes))
    File.delete(@sidecar)
    AdaptivePreviewCapture.write_source_correspondence(@sidecar, graph,
      source_sha256: @source_sha, bomc_sha256: Digest::SHA256.file(@bomc).hexdigest)
    @mapping = JSON.parse(File.read(@sidecar))
    @decoded = BOMEngine::BOMCDecoder.read(@bomc)
    write_evidence

    result = audit
    assert_equal 'verified', result.dig(:correspondence, :status), result.inspect
    assert_equal 'matched', result.dig(:uv_values, :status), result.inspect
    assert_equal 12, result.dig(:uv_values, :compared_scalars)
    assert_equal 'matched', result.dig(:instance_transforms, :status), result.inspect
    assert_equal 16, result.dig(:instance_transforms, :compared_scalars)
    assert_equal false, result[:ready]
    comparison = CaptureFidelityAudit.compare(native_path: @native, decoded: @decoded)
    %i[geometry materials face_bindings tags uv_structure scenes].each do |part|
      assert_includes %w[matched coverage_only], comparison.dig(part, :status), "#{part}: #{comparison.dig(part)}"
    end
  end

  def test_swapped_face_mapping_fails_even_with_same_face_counts
    @mapping['faces'][0]['face'], @mapping['faces'][1]['face'] = 1, 0
    write_evidence
    assert_equal 'mismatch', audit.dig(:uv_values, :status)
  end

  def test_rotated_output_loop_with_matching_uv_is_accepted
    face = @decoded[:meshes][0][:faces][0]
    face[:outer] = [1, 2, 0]
    face[:uv][:front_outer] = [[1, 0.5], [0, 1], [0, 0.5]]
    assert_equal 'matched', audit.dig(:uv_values, :status)
  end

  def test_hole_and_back_side_uvq_are_compared_by_loop_geometry
    native = @native_rows[2]
    native['loops'] << { 'outer' => false,
      'points_m' => [[0.2, 0.2, 0], [0.3, 0.2, 0], [0.2, 0.3, 0]] }
    native['loop_uvq']['front_holes'] = [[[0.4, 0.4, 2], [0.6, 0.4, 2], [0.4, 0.6, 2]]]
    native['loop_uvq']['back_outer'] = [[0, 1, 2], [2, 1, 2], [0, 2, 2]]
    native['loop_uvq']['back_holes'] = [[[0.4, 0.4, 2], [0.6, 0.4, 2], [0.4, 0.6, 2]]]
    mesh = @decoded[:meshes][0]
    mesh[:positions].concat([0.2, 0.2, 0, 0.3, 0.2, 0, 0.2, 0.3, 0])
    face = mesh[:faces][0]
    face[:holes] = [[4, 5, 3]]
    face[:uv][:front_holes] = [[[0.3, 0.2], [0.2, 0.3], [0.2, 0.2]]]
    face[:has_back_uv] = true
    face[:uv][:back_outer] = [[0, 0.5], [1, 0.5], [0, 1]]
    face[:uv][:back_holes] = [[[0.3, 0.2], [0.2, 0.3], [0.2, 0.2]]]
    write_evidence
    result = audit
    assert_equal 'matched', result.dig(:uv_values, :status), result.inspect
    assert_equal 30, result.dig(:uv_values, :compared_scalars)
    face[:uv][:back_holes][0][0][0] = 0.9
    assert_equal 'mismatch', audit.dig(:uv_values, :status)
  end

  def test_uv_and_transform_tampering_fail_independently
    @decoded[:meshes][0][:faces][1][:uv][:front_outer][1][0] = 0.75
    assert_equal 'mismatch', audit.dig(:uv_values, :status)
    @decoded[:meshes][0][:faces][1][:uv][:front_outer][1][0] = 3
    @decoded[:transforms][1][12] = 0.255
    assert_equal 'mismatch', audit.dig(:instance_transforms, :status)
  end

  def test_missing_native_uvq_is_unverifiable_not_matched
    @native_rows[2]['loop_uvq'] = { 'status' => 'unavailable', 'reason' => 'texture_writer_unavailable' }
    write_evidence
    assert_equal 'unverifiable', audit.dig(:uv_values, :status)
  end

  def test_unattested_or_tampered_sidecar_cannot_be_accepted
    @mapping['faces'][0]['source_id'] = 'fabricated'
    File.write(@sidecar, JSON.generate(@mapping))
    assert_equal 'mismatch', audit.dig(:correspondence, :status)
    assert_equal 'unverifiable', audit.dig(:uv_values, :status)
  end

  def test_attested_but_fabricated_face_id_is_not_accepted
    @mapping['faces'][0]['source_id'] = 'fabricated'
    write_evidence
    assert_equal 'mismatch', audit.dig(:correspondence, :status)
    assert_equal 'unverifiable', audit.dig(:uv_values, :status)
  end

  def test_old_native_v1_cannot_claim_numeric_uv_verification
    @native_rows[0]['schema_version'] = 't7-native-reference-raw-v1'
    write_evidence
    assert_equal 'mismatch', audit.dig(:correspondence, :status)
    assert_equal 'unverifiable', audit.dig(:uv_values, :status)
  end

  def test_other_profile_cannot_use_exact_sidecar
    @decoded[:encoding_contract][:profile] = :visual
    assert_equal 'mismatch', audit.dig(:correspondence, :status)
  end

  def test_empty_untextured_model_reports_checks_not_applicable
    @native_rows = [@native_rows.first, @native_rows.last]
    @decoded[:definitions] = [{ kind: 'model_definition', mesh: nil }]
    @decoded[:meshes] = []
    @decoded[:instances] = [@decoded[:instances].first]
    @mapping['definitions'] = [@mapping['definitions'].first]
    @mapping['instances'] = [@mapping['instances'].first]
    @mapping['faces'] = []
    write_evidence
    result = audit
    assert_equal 'verified', result.dig(:correspondence, :status)
    assert_equal 'not_applicable', result.dig(:uv_values, :status)
    assert_equal 'not_applicable', result.dig(:instance_transforms, :status)
  end
end
