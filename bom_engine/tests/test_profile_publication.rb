# frozen_string_literal: true
# Unit and integration tests for BOMC Profile Publication (Track T3)
# Tests:
# 1. Profile propagation spy: exact/research/visual reach snapshot_model and BOMCTextureOptimizer.stage
# 2. Shared texture class resolution: shared Class A/C texture resolves to strictest Class A
# 3. 39 dB candidate rejected by Research (falls back to PNG), accepted by Visual Class B/C
# 4. Alpha texture never converted to JPEG (preserves lossless PNG)
# 5. Mutation matrix: coordinate, UV, transform, scene mask, semantic ID, topology edge, texture pixel
# 6. Atomic publication: validation failure preserves destination, cleans up .part

require 'test/unit'
require 'fileutils'
require 'tmpdir'
require 'json'
require_relative '../bomc_extension'
require_relative '../bomc_validator'
require_relative '../bomc_texture_optimizer'
require_relative '../bomc_texture_policy'
require_relative '../bomc_size_gate'
require_relative '../bomc_decoder'
require_relative '../bomc_writer'
require_relative '../material_extractor'

class TestProfilePublication < Test::Unit::TestCase
  FakeImageRep = Struct.new(:width, :height, :bits_per_pixel, :row_padding, :data) do
    def save_file(path)
      File.open(path, 'wb') { |file| file.write('j' * 1_000) }
      true
    end
  end

  FakeColor = Struct.new(:red, :green, :blue, :alpha)
  FakeMaterial = Struct.new(:object_id, :name, :display_name, :color, :alpha, :materialType, :texture)
  FakeModel = Struct.new(:materials, :entities, :material_classes)

  class FakeTexture
    attr_reader :filename, :width, :height, :image_width, :image_height

    def initialize(filename, reference)
      @filename = filename
      @reference = reference
      @width = 10.0
      @height = 10.0
      @image_width = reference.width
      @image_height = reference.height
    end

    def write(path, _colorized)
      bytes = File.extname(path).downcase == '.jpg' ? 1_000 : 10_000
      File.open(path, 'wb') { |file| file.write('x' * bytes) }
      true
    end

    def image_rep(_colorized)
      @reference
    end
  end

  def setup
    root = File.expand_path('../..', __dir__)
    fixture_path = File.join(root, 'examples', 'model-eval-json-v1-small.json')
    @graph = JSON.parse(File.read(fixture_path), symbolize_names: true)
  end

  def make_image_rep(pixels, alpha: nil, row_padding: 0)
    channels = alpha ? 4 : 3
    rows = pixels.each_slice(2).each_with_index.map do |row, row_index|
      bytes = row.each_with_index.flat_map do |rgb, column_index|
        values = rgb.dup
        values << alpha[row_index * 2 + column_index] if alpha
        values
      end
      bytes.pack('C*') + ("\0" * row_padding)
    end
    FakeImageRep.new(2, 2, channels * 8, row_padding, rows.join.b)
  end

  def deep_dup(obj)
    Marshal.load(Marshal.dump(obj))
  end

  # Test 1: Spy test that :exact, :research, :visual reach snapshot_model and BOMCTextureOptimizer.stage
  def test_profile_propagation_spy
    [:exact, :research, :visual].each do |target_profile|
      seen_optimizer_profile = nil
      optimizer_singleton = class << BOMEngine::BOMCTextureOptimizer; self; end
      original_stage = optimizer_singleton.instance_method(:stage)
      optimizer_singleton.define_method(:stage) do |**kwargs, &block|
        seen_optimizer_profile = kwargs[:profile]
        original_stage.bind(self).call(**kwargs, &block)
      end

      ref = make_image_rep([[10, 20, 30], [40, 50, 60], [70, 80, 90], [100, 110, 120]])
      tex = FakeTexture.new('textures/wood.png', ref)
      mat = FakeMaterial.new(101, 'Wood', 'Wood', FakeColor.new(200, 150, 100, 255), 1.0, 1, tex)
      model = FakeModel.new([mat], [], nil)

      tmp_dir = Dir.mktmpdir('spy-test')
      begin
        BOMEngine::BOMCExtension.send(:snapshot_model, model, tmp_dir, ->(**_) {}, profile: target_profile)
      ensure
        optimizer_singleton.define_method(:stage, original_stage)
        FileUtils.remove_entry(tmp_dir) if tmp_dir && Dir.exist?(tmp_dir)
      end

      assert_equal target_profile, seen_optimizer_profile,
                   "Profile #{target_profile} must reach BOMCTextureOptimizer.stage"
    end
  end

  # Test 2: Shared texture Class A/C resolves to strictest Class A
  def test_non_hash_model_material_classes_is_not_used_as_an_index
    indexed_collection = Object.new
    indexed_collection.define_singleton_method(:[]) do |index|
      raise IndexError, "index #{index} too big"
    end
    model = FakeModel.new([], [], indexed_collection)

    assert_equal({}, BOMEngine::BOMCExtension.compute_material_classes(model))
  end

  def test_material_class_merge_does_not_require_flat_map
    graph = {
      materials: [{ id: 'mat', name: 'Material', texture: { filename: 'shared.png' } }],
      meshes: [{ faces: [{ front_material: 0, semantic_role: 'exterior_wall' }] }],
      nodes: []
    }
    assert_equal :class_a, BOMEngine::BOMCExtension.compute_material_classes_from_graph(graph)['Material']
  end

  def test_shared_texture_strictest_semantic_class
    graph = {
      materials: [
        { id: 'mat-wall', name: 'WallMaterial', texture: { filename: 'shared_wood.png' } },
        { id: 'mat-chair', name: 'ChairMaterial', texture: { filename: 'shared_wood.png' } }
      ],
      meshes: [
        {
          id: 'mesh-1',
          positions_m: [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0],
          faces: [
            { front_material: 0, semantic_role: 'exterior_wall' }, # Class A
            { front_material: 1, semantic_role: 'furniture' }     # Class C
          ]
        }
      ],
      nodes: []
    }

    resolved = BOMEngine::BOMCExtension.compute_material_classes_from_graph(graph)
    assert_equal :class_a, resolved['WallMaterial'], 'Wall material must be Class A'
    assert_equal :class_a, resolved['ChairMaterial'], 'Shared texture must elevate Chair material to Class A'

    classes = [
      BOMEngine::BOMCGeometryPolicy.classify_role(:exterior_wall),
      BOMEngine::BOMCGeometryPolicy.classify_role(:furniture)
    ]
    strictest = BOMEngine::BOMCTexturePolicy.strictest_semantic_class(classes)
    assert_equal :class_a, strictest, 'Strictest semantic class for Class A and Class C must be Class A'
  end

  # A frequently reused texture previously duplicated every usage for every
  # face, constructing an N*N array. Restrict reduction to the 3 unique classes.
  def with_bounded_class_reduction
    policy = BOMEngine::BOMCTexturePolicy
    original = policy.method(:strictest_semantic_class)
    policy.define_singleton_method(:strictest_semantic_class) do |classes|
      raise "Unbounded class reduction: #{classes.length} entries" if classes.length > 3
      original.call(classes)
    end
    yield
  ensure
    policy.define_singleton_method(:strictest_semantic_class, original) if original
  end

  def test_repeated_live_material_usage_has_bounded_reduction
    texture = Struct.new(:filename).new('shared.png')
    material_type = Struct.new(:name, :texture)
    wall = material_type.new('Wall', texture)
    chair = material_type.new('Chair', texture)
    face_type = Struct.new(:material, :back_material, :semantic_role)
    entities = Array.new(20_000) { face_type.new(chair, chair, :furniture) }
    entities << face_type.new(wall, nil, :wall)
    with_bounded_class_reduction do
      resolved = BOMEngine::BOMCExtension.compute_material_classes(FakeModel.new([wall, chair], entities, nil))
      assert_equal :class_a, resolved['Wall']
      assert_equal :class_a, resolved['Chair']
    end
  end

  def test_repeated_graph_material_usage_has_bounded_reduction
    graph = {
      materials: [
        { id: 'wall', name: 'Wall', texture: { filename: 'shared.png' } },
        { id: 'chair', name: 'Chair', texture: { filename: 'shared.png' } }
      ],
      meshes: [{ faces: Array.new(20_000) { { front_material: 1, semantic_role: :furniture } } +
        [{ front_material: 0, semantic_role: :wall }] }], nodes: []
    }
    with_bounded_class_reduction do
      resolved = BOMEngine::BOMCExtension.compute_material_classes_from_graph(graph)
      assert_equal :class_a, resolved['Wall']
      assert_equal :class_a, resolved['Chair']
    end
  end

  # Test 3: 39 dB opaque non-native candidate is rejected by Research, accepted by Visual Class B/C
  def test_research_rejects_39db_and_visual_accepts
    ref = make_image_rep([
      [10, 20, 30], [40, 50, 60],
      [70, 80, 90], [100, 110, 120]
    ])
    # Delta of 5 on 4 samples: MSE = (25 * 4) / 12 = 8.333, PSNR = ~38.92 dB (approx 39 dB)
    cand_39db = make_image_rep([
      [15, 20, 30], [40, 55, 60],
      [75, 80, 90], [100, 115, 120]
    ])

    quality = BOMEngine::BOMCTextureOptimizer.compare(ref, cand_39db)
    assert quality[:compatible]
    assert quality[:psnr_db] >= 38.0 && quality[:psnr_db] < 40.0, "Candidate PSNR must be around 39 dB (was #{quality[:psnr_db]})"

    Dir.mktmpdir('psnr-test') do |dir|
      staged_png = File.join(dir, 'test.png')
      candidate_jpg = File.join(dir, 'test.jpg')
      File.binwrite(staged_png, 'p' * 10_000)
      File.binwrite(candidate_jpg, 'j' * 1_000)

      # In Research: threshold is 42.0 dB, 39 dB must fail and fall back to staged_png
      research_result = BOMEngine::BOMCTextureOptimizer.select(
        staged_path: staged_png,
        candidate_path: candidate_jpg,
        reference: ref,
        candidate: cand_39db,
        native_jpeg: false,
        profile: :research,
        semantic_class: :class_b
      )
      assert_equal :staged_png, research_result[:selected], 'Research must reject 39 dB candidate'
      assert_equal :quality_gate_failed, research_result[:reason], 'Research must report quality_gate_failed'
      assert_in_delta 42.0, research_result[:quality_threshold_psnr_db], 0.01

      # In Visual Class B: threshold is 38.0 dB, 39 dB must pass and select jpeg_candidate
      visual_b_result = BOMEngine::BOMCTextureOptimizer.select(
        staged_path: staged_png,
        candidate_path: candidate_jpg,
        reference: ref,
        candidate: cand_39db,
        native_jpeg: false,
        profile: :visual,
        semantic_class: :class_b
      )
      assert_equal :jpeg_candidate, visual_b_result[:selected], 'Visual Class B must accept 39 dB candidate'
      assert_in_delta 38.0, visual_b_result[:quality_threshold_psnr_db], 0.01

      # In Visual Class C: threshold is 35.0 dB, 39 dB must pass
      visual_c_result = BOMEngine::BOMCTextureOptimizer.select(
        staged_path: staged_png,
        candidate_path: candidate_jpg,
        reference: ref,
        candidate: cand_39db,
        native_jpeg: false,
        profile: :visual,
        semantic_class: :class_c
      )
      assert_equal :jpeg_candidate, visual_c_result[:selected], 'Visual Class C must accept 39 dB candidate'
      assert_in_delta 35.0, visual_c_result[:quality_threshold_psnr_db], 0.01
    end
  end

  # Test 4: Alpha texture is never converted to JPEG
  def test_alpha_texture_never_converted_to_jpeg
    ref_alpha = make_image_rep([
      [10, 20, 30], [40, 50, 60],
      [70, 80, 90], [100, 110, 120]
    ], alpha: [255, 255, 128, 255])
    cand = make_image_rep([
      [10, 20, 30], [40, 50, 60],
      [70, 80, 90], [100, 110, 120]
    ])

    Dir.mktmpdir('alpha-test') do |dir|
      staged_png = File.join(dir, 'alpha.png')
      candidate_jpg = File.join(dir, 'alpha.jpg')
      File.binwrite(staged_png, 'p' * 10_000)
      File.binwrite(candidate_jpg, 'j' * 1_000)

      result = BOMEngine::BOMCTextureOptimizer.select(
        staged_path: staged_png,
        candidate_path: candidate_jpg,
        reference: ref_alpha,
        candidate: cand,
        native_jpeg: true, # Even with native JPEG hint!
        profile: :visual,
        semantic_class: :class_c
      )
      assert_equal :staged_png, result[:selected], 'Alpha texture must never select JPEG'
      assert_equal :alpha_requires_lossless, result[:reason], 'Alpha reason must be alpha_requires_lossless'
    end
  end

  # Test 5: Mutation test: mutating coordinate, UV, transform, scene mask, semantic ID, topology edge, texture pixel
  def test_mutation_matrix_fails_validation
    candidate = BOMEngine::BOMCSizeGate.compile_candidate(@graph, profile: :exact)
    decoded = BOMEngine::BOMCDecoder.decode(candidate.fetch(:bytes))

    # Baseline decoded must pass validate_profile!
    base_report = BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: decoded, profile: :exact)
    assert_equal true, base_report[:passed], 'Baseline decoded graph must pass exact validation'

    # Mutation 1: Coordinate
    m_coord = deep_dup(decoded)
    m_coord[:meshes][0][:positions][0] += 0.05
    assert_raise(BOMEngine::BOMCValidator::ProfileValidationError, 'Coordinate mutation must fail validation') do
      BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: m_coord, profile: :exact)
    end

    # Mutation 2: UV
    m_uv = deep_dup(decoded)
    if m_uv[:meshes][0][:faces][0][:uv] && m_uv[:meshes][0][:faces][0][:uv][:front_outer]
      m_uv[:meshes][0][:faces][0][:uv][:front_outer][0] += 0.05
    else
      m_uv[:meshes][0][:faces][0][:uv] = { front_outer: [0.5, 0.5] }
    end
    assert_raise(BOMEngine::BOMCValidator::ProfileValidationError, 'UV mutation must fail validation') do
      BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: m_uv, profile: :exact)
    end

    # Mutation 3: Transform
    m_xform = deep_dup(decoded)
    m_xform[:transforms][0][0] += 0.05
    assert_raise(BOMEngine::BOMCValidator::ProfileValidationError, 'Transform mutation must fail validation') do
      BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: m_xform, profile: :exact)
    end

    # Mutation 4: Scene mask
    m_scene = deep_dup(decoded)
    m_scene[:scenes] = [{ name: 'Scene 1', tag_visibility: ['mutated_tag'], hidden_instances: [] }]
    graph_scenes = @graph.merge(scenes: [{ name: 'Scene 1', tag_visibility: ['original_tag'], hidden_instances: [] }])
    assert_raise(BOMEngine::BOMCValidator::ProfileValidationError, 'Scene mask mutation must fail validation') do
      BOMEngine::BOMCValidator.validate_profile!(source: graph_scenes, decoded: m_scene, profile: :exact)
    end

    # Mutation 5: Semantic ID / role
    m_sem = deep_dup(decoded)
    m_sem[:instances][0][:semantic_role] = 'mutated_semantic_role'
    assert_raise(BOMEngine::BOMCValidator::ProfileValidationError, 'Semantic ID mutation must fail validation') do
      BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: m_sem, profile: :exact)
    end

    # Mutation 6: Topology edge
    m_topo = deep_dup(decoded)
    if m_topo[:meshes][0][:edges] && m_topo[:meshes][0][:edges].any?
      m_topo[:meshes][0][:edges][0][:vertices] = [999, 999]
    else
      m_topo[:meshes][0][:faces][0][:outer] = [999, 999, 999]
    end
    assert_raise(BOMEngine::BOMCValidator::ProfileValidationError, 'Topology edge mutation must fail validation') do
      BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: m_topo, profile: :exact)
    end

    # Mutation 7: Texture pixel mutation
    ref_px = make_image_rep([[10, 20, 30], [40, 50, 60], [70, 80, 90], [100, 110, 120]])
    mutated_px = make_image_rep([[15, 20, 30], [40, 50, 60], [70, 80, 90], [100, 110, 120]]) # 1 pixel channel mutated
    mutated_texture_evidence = [
      {
        filename: 'wood.png',
        reference: ref_px,
        candidate: mutated_px,
        native_jpeg: false
      }
    ]
    assert_raise(BOMEngine::BOMCValidator::ProfileValidationError, 'Texture pixel mutation must fail exact validation') do
      BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: decoded, profile: :exact, texture_evidence: mutated_texture_evidence)
    end
  end

  # Test 6: Atomic publication test: validation failure preserves pre-existing file, cleans up .part
  def test_atomic_publication_preserves_destination_on_failure
    Dir.mktmpdir('atomic-pub-test') do |dir|
      destination = File.join(dir, 'output.bomc')
      initial_content = 'PRE_EXISTING_COMMITTED_DATA'
      File.binwrite(destination, initial_content)

      candidate = BOMEngine::BOMCSizeGate.compile_candidate(@graph, profile: :exact)
      failing_report = { passed: false, failures: ['Simulated validation failure'] }

      assert_raise(BOMEngine::BOMCValidator::ProfileValidationError) do
        BOMEngine::BOMCExtension.publish_validated(
          candidate: candidate,
          report: failing_report,
          output_path: destination
        )
      end

      # Verify destination file was untouched
      assert_equal initial_content, File.read(destination), 'Pre-existing file must remain untouched on validation failure'
      # Verify no stray .part files left
      part_files = Dir.glob(File.join(dir, '*.part'))
      assert part_files.empty?, "Stray .part files must be cleaned up (found: #{part_files})"

      # Now verify passing publication succeeds and overwrites cleanly
      passing_report = { passed: true, failures: [] }
      published = BOMEngine::BOMCExtension.publish_validated(
        candidate: candidate,
        report: passing_report,
        output_path: destination
      )
      assert_equal true, published[:published]
      assert_equal File.size(destination), published[:bytes]
      assert_not_equal initial_content, File.read(destination), 'Destination must be updated when validation passes'
      assert Dir.glob(File.join(dir, '*.part')).empty?, 'No .part files must remain after successful publication'
    end
  end
end
