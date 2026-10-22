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

  def test_strict_native_exact_rechecks_saved_source_at_publication
    Dir.mktmpdir('bomc-strict-publish', 'D:/projects/sibambo/scratch') do |directory|
      source_path = File.join(directory, 'original.skp')
      output_path = File.join(directory, 'result.bomc')
      File.binwrite(source_path, 'a' * 1_000_000)
      File.binwrite(output_path, 'previous-good-artifact')
      info = BOMEngine::BOMCSizeGate.source_info(source_path)
      candidate = BOMEngine::BOMCSizeGate.compile_candidate(@graph, profile: :exact,
        source_info: info, strict_exact_source: true)
      decoded = BOMEngine::BOMCDecoder.decode(candidate[:bytes])
      validation = BOMEngine::BOMCValidator.validate_profile!(source: @graph,
        decoded: decoded, profile: :exact, normalized_source: candidate[:normalized_source])

      File.binwrite(source_path, 'b' * 1_000_000)
      assert_raise(ArgumentError) do
        BOMEngine::BOMCExtension.publish_validated(candidate: candidate, report: validation,
          output_path: output_path, source_info: info)
      end
      assert_equal 'previous-good-artifact', File.binread(output_path)
      assert_equal [], Dir.glob(File.join(directory, '*.part'))

      File.binwrite(source_path, 'a' * 1_000_000)
      published = BOMEngine::BOMCExtension.publish_validated(candidate: candidate,
        report: validation, output_path: output_path, source_info: info)
      assert_equal true, published[:published]
      assert_operator File.size(output_path), :<, File.size(source_path)
      assert_equal candidate[:sha256], Digest::SHA256.file(output_path).hexdigest
    end
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

  def test_adaptive_nested_texture_evidence_is_validated
    candidate = BOMEngine::BOMCSizeGate.compile_candidate(@graph, profile: :exact)
    decoded = BOMEngine::BOMCDecoder.decode(candidate.fetch(:bytes))
    evidence = { selected: :staged, staging: {
      policy_revision: 'adaptive-texture-1', profile: :research,
      selected: :webp_candidate, alpha_preserved: true, native_jpeg: false,
      semantic_class: :class_b, quality: { compatible: true, alpha_preserved: true,
        psnr_db: 48.0, mean_squared_error: 1.0, max_channel_error: 1 }
    } }
    assert_nothing_raised do
      BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: decoded, profile: :research, texture_evidence: [evidence])
    end
    [
      { psnr_db: 20.0 }, { psnr_db: Float::NAN }, { alpha_preserved: false },
      { psnr_db: nil, mean_squared_error: 2.0 }, { compatible: false }
    ].each do |mutation|
      bad = deep_dup(evidence)
      bad[:staging][:quality].merge!(mutation)
      assert_raise(BOMEngine::BOMCValidator::ProfileValidationError, mutation.inspect) do
        BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: decoded, profile: :research, texture_evidence: [bad])
      end
    end
  end

  def test_validator_accepts_compiler_normalized_source_without_rematerializing_raw_input
    candidate = BOMEngine::BOMCSizeGate.compile_candidate(@graph, profile: :exact)
    decoded = BOMEngine::BOMCDecoder.decode(candidate.fetch(:bytes))
    report = BOMEngine::BOMCValidator.validate_profile!(
      source: Object.new,
      normalized_source: candidate.fetch(:normalized_source),
      decoded: decoded,
      profile: :exact
    )
    assert_equal true, report[:passed]
  end

  def test_streaming_error_accumulator_preserves_exact_p95_and_rms
    values = (1..101).to_a.reverse.map(&:to_f)
    accumulator = BOMEngine::BOMCValidator::ErrorAccumulator.new(max_count: values.length)
    values.each { |value| accumulator.add(value) }
    result = accumulator.summary
    expected_p95 = values.sort[(values.length * 0.95).ceil - 1]
    expected_rms = Math.sqrt(values.inject(0.0) { |sum, value| sum + value * value } / values.length)
    assert_equal 101.0, result[:max]
    assert_equal expected_p95, result[:p95]
    assert_in_delta expected_rms, result[:rms], 1.0e-12
  end

  def test_exact_decoded_jpeg_requires_matching_lossless_digest_evidence
    decoded = BOMEngine::BOMCDecoder.decode(BOMEngine::BOMCWriter.pack(@graph, profile: :exact)[:bytes])
    digest = Digest::SHA256.hexdigest('jpeg-payload')
    # The real decoder emits :jpeg and a SHA, not image/jpeg or a filename.
    decoded[:textures] = [{ media_type: :jpeg, sha256: digest, bytes: 'jpeg-payload' }]
    assert_raise(BOMEngine::BOMCValidator::ProfileValidationError) do
      BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: decoded, profile: :exact)
    end
    evidence = { staging: {
      policy_revision: 'adaptive-texture-3', profile: :exact, native_jpeg: true,
      selected: :native_jpeg_candidate, selected_sha256: digest, alpha_preserved: true,
      quality: { compatible: true, alpha_preserved: true, mean_squared_error: 0.0, max_channel_error: 0 }
    } }
    assert_nothing_raised do
      BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: decoded,
        profile: :exact, texture_evidence: [evidence])
    end
    bad = deep_dup(evidence)
    bad[:staging][:selected_sha256] = Digest::SHA256.hexdigest('other-texture')
    assert_raise(BOMEngine::BOMCValidator::ProfileValidationError) do
      BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: decoded,
        profile: :exact, texture_evidence: [bad])
    end
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

  def test_snapshot_passes_scoped_candidate_cache_to_texture_optimizer
    seen_cache = nil
    optimizer = BOMEngine::BOMCTextureOptimizer
    original = optimizer.method(:stage)
    optimizer.define_singleton_method(:stage) do |**kwargs, &block|
      seen_cache = kwargs[:candidate_cache]
      original.call(**kwargs, &block)
    end
    ref = make_image_rep([[10, 20, 30], [40, 50, 60], [70, 80, 90], [100, 110, 120]])
    material = FakeMaterial.new(101, 'Wood', 'Wood', FakeColor.new(200, 150, 100, 255),
      1.0, 1, FakeTexture.new('textures/wood.png', ref))
    model = FakeModel.new([material], [], nil)
    Dir.mktmpdir('snapshot-cache') do |root|
      cache_dir = File.join(root, 'cache')
      Dir.mkdir(cache_dir)
      cache = { directory: cache_dir, entries: {}, hits: 0 }
      error = nil
      begin
        BOMEngine::BOMCExtension.send(:snapshot_model, model, File.join(root, 'textures'),
          ->(**_) {}, profile: :visual, candidate_cache: cache)
      rescue ArgumentError => caught
        error = caught
      end
      assert_nil error
      assert_same cache, seen_cache
    end
  ensure
    optimizer.define_singleton_method(:stage, original) if original
  end

  def test_experimental_opt_in_and_shared_pixel_budget_reach_texture_staging
    seen=[]
    original=BOMEngine::BOMCTextureOptimizer.method(:stage)
    BOMEngine::BOMCTextureOptimizer.define_singleton_method(:stage) do |**kwargs,&block|
      seen << kwargs.slice(:allow_jpeg_color_map,:color_map_budget)
      original.call(**kwargs,&block)
    end
    ref=make_image_rep([[10,20,30],[40,50,60],[70,80,90],[100,110,120]])
    mats=2.times.map { |i| FakeMaterial.new(i,"M#{i}","M#{i}",FakeColor.new(255,255,255,255),1.0,1,FakeTexture.new('embedded.png',ref)) }
    Dir.mktmpdir do |dir|
      assert_nothing_raised { BOMEngine::BOMCExtension.send(:snapshot_model,FakeModel.new(mats,[],nil),dir,->(**_) {},profile: :exact,allow_jpeg_color_map:true) }
    end
    assert_equal [true,true],seen.map { |item| item[:allow_jpeg_color_map] }
    assert_same seen[0][:color_map_budget],seen[1][:color_map_budget]
    assert_equal 128_000_000,seen[0][:color_map_budget][:remaining_pixels]
  ensure
    BOMEngine::BOMCTextureOptimizer.define_singleton_method(:stage,original) if original
  end

  def test_exact_jcm_stages_largest_jpeg_textures_first_without_reordering_materials
    calls = []
    optimizer = BOMEngine::BOMCTextureOptimizer
    original = optimizer.method(:stage)
    optimizer.define_singleton_method(:stage) do |**kwargs, &block|
      calls << [kwargs[:source_path], kwargs[:texture].image_width * kwargs[:texture].image_height]
      path = File.join(kwargs[:directory], "#{kwargs[:basename]}.png")
      File.binwrite(path, 'x')
      { path: path, filename: File.basename(path), evidence: { selected: :staged_png } }
    end

    image = ->(w, h) { FakeImageRep.new(w, h, 24, 0, "\0".b * (w * h * 3)) }
    small = FakeMaterial.new(1, 'Small', 'Small', FakeColor.new(255,255,255,255), 1.0, 1,
      FakeTexture.new('small.jpg', image.call(100, 100)))
    png = FakeMaterial.new(2, 'Png', 'Png', FakeColor.new(255,255,255,255), 1.0, 1,
      FakeTexture.new('large.png', image.call(1000, 1000)))
    large = FakeMaterial.new(3, 'Large', 'Large', FakeColor.new(255,255,255,255), 1.0, 1,
      FakeTexture.new('large.jpg', image.call(2000, 2000)))
    model = FakeModel.new([small, png, large], [], nil)

    Dir.mktmpdir('jcm-priority') do |dir|
      result = BOMEngine::MaterialExtractor.extract(model, nil, dir,
        optimize_textures: true, profile: :exact, allow_jpeg_color_map: true)
      assert_equal ['Small', 'Png', 'Large'], result.map { |row| row[:name] },
        'material output order must stay source-stable'
    end
    assert_equal ['large.jpg', 'small.jpg', 'large.png'], calls.map(&:first),
      'Exact JCM must measure the largest JPEG-backed textures before lower-impact candidates'
  ensure
    optimizer.define_singleton_method(:stage, original) if original
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

      # Emission-time digest verification must also fail before replacing the
      # committed destination and must clean the staged file.
      tampered_digest = candidate.merge(sha256: '0' * 64)
      assert_raise(IOError) do
        BOMEngine::BOMCExtension.publish_validated(
          candidate: tampered_digest,
          report: { passed: true, failures: [] },
          output_path: destination
        )
      end
      assert_equal initial_content, File.read(destination), 'Digest mismatch must preserve the committed destination'
      assert Dir.glob(File.join(dir, '*.part')).empty?, 'Digest mismatch must clean the staged file'

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
