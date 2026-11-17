# frozen_string_literal: true

require 'test/unit'
require_relative 'support/harness'

# Both cores (BOMC side and SketchUp side on the mock) plus the comparator.
class TestEndToEndSynthetic < Test::Unit::TestCase
  def setup
    UI.instance_variable_set(:@callback, nil)
  end

  def teardown
    SibamboModelTruthV1::SkpSide.reset!
    Sketchup.version = nil
  end

  def run_e2e(**opts)
    E2E.capture(**opts)
  end

  def v(diff)
    E2E.verdicts(diff)
  end

  def cat(diff, name)
    E2E.category(diff, name)
  end

  def assert_only_fail(diff, *failing)
    # D26: any geometry change makes the definition multiset differ, so `definitions` fails with it.
    failing += ['definitions'] unless (failing & %w[faces edges instances images texts]).empty?
    expected = E2E::CATS.map { |c| [c, failing.include?(c) ? 'FAIL' : 'PASS'] }.to_h
    assert_equal expected, v(diff)
    assert_equal(failing.empty? ? 'PASS' : 'FAIL', diff[:overall])
  end

  def fields(diff, name)
    cat(diff, name)[:firstMismatches].map { |m| m[:field] }
  end

  def test_identical_models_pass_everything
    r = run_e2e
    d = r.diff
    assert_equal 'PASS', d[:overall]
    assert_only_fail(d)
    assert_equal true, d[:root][:equal]
    assert_equal true, d[:definitions_multiset_equal]
    assert_equal 3, cat(d, 'faces')[:skpCount]
    assert_equal 3, cat(d, 'faces')[:matches]
    assert_equal [{ category: 'image_pixels', reason: 'D22', skpCount: 1 }], d[:not_run]
    assert_equal 'Fixture Model', d[:model]
    assert File.exist?(File.join(r.run_dir, 'model-truth-diff.json'))
    assert_raise(Errno::EEXIST) { SibamboModelTruthV1::Compare.run(run_dir: r.run_dir) }
  end

  def test_result_does_not_depend_on_fiber_budget
    a = run_e2e(budget_records: 1).diff
    b = run_e2e(budget_records: 1000).diff
    assert_equal a[:root], b[:root]
    assert_equal 'PASS', a[:overall]
    assert_equal 'PASS', b[:overall]
  end

  def test_uv_change_fails_faces_with_uv_front
    d = run_e2e(decoded_mutator: ->(h) { h[:meshes][0][:faces][0][:uv][:front_outer][0][0] += 1e-3 }).diff
    assert_only_fail(d, 'faces')
    assert_include fields(d, 'faces'), 'uv_front'
    assert_equal false, d[:root][:equal]
  end

  def test_instance_paint_change_fails_instances_with_material
    d = run_e2e(decoded_mutator: ->(h) { h[:instances][2][:material] = nil }).diff
    assert_only_fail(d, 'instances')
    assert_equal ['material'], fields(d, 'instances')
  end

  def test_face_material_dropped_fails_faces_with_front_material
    d = run_e2e(decoded_mutator: ->(h) { h[:meshes][0][:faces][0][:front_material] = nil }).diff
    assert_only_fail(d, 'faces')
    assert_equal ['front_material'], fields(d, 'faces')
  end

  def test_missing_edge_fails_edges_with_missing_in_bomc
    d = run_e2e(decoded_mutator: ->(h) { h[:meshes][0][:edges].pop }).diff
    assert_only_fail(d, 'edges')
    assert_equal ['missing_in_bomc'], fields(d, 'edges')
  end

  def test_extra_edge_fails_edges_with_extra_in_bomc
    d = run_e2e(decoded_mutator: lambda { |h|
      h[:meshes][0][:edges] << { vertices: [0, 2], tag: nil, hidden: false, soft: false, smooth: false }
    }).diff
    assert_only_fail(d, 'edges')
    assert_equal ['extra_in_bomc'], fields(d, 'edges')
  end

  def test_edge_flag_change
    d = run_e2e(decoded_mutator: ->(h) { h[:meshes][0][:edges][0][:soft] = true }).diff
    assert_only_fail(d, 'edges')
    assert_equal ['soft'], fields(d, 'edges')
  end

  def test_leaf_change_in_shared_definition_is_local_and_propagates
    d = run_e2e(decoded_mutator: ->(h) { h[:meshes][1][:faces][0][:hidden] = true }).diff
    assert_only_fail(d, 'faces')
    assert_equal ['hidden'], fields(d, 'faces')
    pairs = d[:diagnostics][:definition_pairs]
    comp = pairs.find { |p| p[:kind] == 'component' }
    root = pairs.find { |p| p[:kind] == 'root' }
    assert_equal ['faces'], comp[:local_categories]
    assert_equal true, root[:propagated]
    assert_equal [], root[:local_categories]
    assert_equal 1, d[:diagnostics][:propagated_count]
    # the propagated root is counted, not listed as a face mismatch
    assert_equal 1, cat(d, 'faces')[:firstMismatches].length
  end

  def test_start_vertex_rotation_passes
    d = run_e2e(decoded_mutator: lambda { |h|
      f = h[:meshes][0][:faces][0]
      f[:outer] = f[:outer].rotate(2)
      f[:uv][:front_outer] = f[:uv][:front_outer].rotate(2)
    }).diff
    assert_only_fail(d)
  end

  def test_winding_reversal_fails_with_outer_positions
    d = run_e2e(decoded_mutator: lambda { |h|
      f = h[:meshes][0][:faces][0]
      f[:outer] = f[:outer].reverse
      f[:uv][:front_outer] = f[:uv][:front_outer].reverse
    }).diff
    assert_only_fail(d, 'faces')
    assert_include fields(d, 'faces'), 'outer_positions'
  end

  def test_triangle_difference_with_equal_loops_fails_with_triangles
    d = run_e2e(decoded_mutator: ->(h) { h[:meshes][0][:faces][0][:triangles] = [0, 1, 3, 1, 2, 3] }).diff
    assert_only_fail(d, 'faces')
    assert_equal ['triangles'], fields(d, 'faces')
  end

  def test_definition_split_fails_definitions_with_equal_root
    d = run_e2e(decoded_mutator: lambda { |h|
      h[:definitions] << h[:definitions][1].dup
      h[:instances][2][:definition] = h[:definitions].length - 1
    }).diff
    assert_equal true, d[:root][:equal]
    assert_equal false, d[:definitions_multiset_equal]
    assert_equal 'FAIL', d[:overall]
    assert_equal 'FAIL', v(d)['definitions']
    assert_equal 1, d[:diagnostics][:unpaired][:bomc].length
    assert_equal 4, cat(d, 'definitions')[:bomcCount]
    assert_equal 3, cat(d, 'definitions')[:skpCount]
  end

  def test_texture_pixel_mismatch_fails_textures_pixels
    d = run_e2e(decoded_mutator: lambda { |h|
      h[:textures][0][:bytes] = JSON.generate('w' => 2, 'h' => 2, 'bgr' => [1] * 12).b
    }).diff
    assert_only_fail(d, 'textures_pixels')
    assert_equal ['pixel_sha256'], fields(d, 'textures_pixels')
  end

  def semantic_spec
    spec = MTFixture.spec
    spec[:textures][0][:bgr_false] = [9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 11, 12]
    spec[:materials][0] = spec[:materials][0].merge(type: 2, semantic: { type: 'tint', deltas: [0.25, -0.5, 0.125] })
    spec
  end

  def test_semantic_colorize_uses_base_pixels_and_checks_output_and_deltas
    r = run_e2e(spec: semantic_spec)
    assert_only_fail(r.diff)
    d = run_e2e(spec: semantic_spec, decoded_mutator: ->(h) { h[:materials][0][:colorize_deltas][:l] = -0.5000000000000001 }).diff
    assert_only_fail(d, 'textures_colorize')
    assert_equal ['colorize_deltas'], fields(d, 'textures_colorize')
    d = run_e2e(spec: semantic_spec, decoded_mutator: ->(h) { h[:materials][0][:colorize_type] = 'shift' }).diff
    assert_equal ['colorize_type'], fields(d, 'textures_colorize')
    d = run_e2e(spec: semantic_spec, decoded_mutator: ->(h) { h[:materials][0][:colorize_output_sha256] = 'e' * 64 }).diff
    assert_equal ['colorize_output_sha256'], fields(d, 'textures_colorize')
  end

  def test_semantic_material_whose_bomc_texture_is_the_colorized_image_fails_pixels
    d = run_e2e(spec: semantic_spec, decoded_mutator: lambda { |h|
      h[:textures][0][:bytes] = JSON.generate('w' => 2, 'h' => 2, 'bgr' => [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]).b
    }).diff
    assert_equal 'FAIL', v(d)['textures_pixels']
  end

  def spec_with(**texture_opts)
    spec = MTFixture.spec
    spec[:textures][0].merge!(texture_opts)
    spec
  end

  def test_unneeded_image_rep_side_failing_does_not_fail_non_semantic_texture
    d = run_e2e(spec: spec_with(bpp_false: 8)).diff
    assert_only_fail(d)
    info = d[:diagnostics][:texture_info]
    assert_equal 1, d[:diagnostics][:texture_info_count]
    assert_equal 'unneeded_side_failed', info[0][:field]
    assert_equal 'false', info[0][:flag].to_s
    assert_equal 8, info[0][:bits_per_pixel]
    assert_equal 'info', info[0][:severity]
  end

  def test_needed_image_rep_side_failing_fails_non_semantic_texture
    d = run_e2e(spec: spec_with(bpp_true: 8)).diff
    assert_only_fail(d, 'textures_pixels')
    m = cat(d, 'textures_pixels')[:firstMismatches]
    assert_equal ['skp_image_rep_error'], m.map { |x| x[:field] }
    assert_equal 8, m[0][:bits_per_pixel]
    assert_equal 'true', m[0][:flag].to_s
  end

  def test_semantic_material_needs_both_sides
    base = lambda { semantic_spec }
    s1 = base.call
    s1[:textures][0][:bpp_false] = 8
    d = run_e2e(spec: s1).diff
    assert_equal 'FAIL', v(d)['textures_pixels']
    assert_equal 'FAIL', v(d)['textures_colorize']
    assert_equal ['skp_image_rep_error'], fields(d, 'textures_pixels')
    s2 = base.call
    s2[:textures][0][:bpp_true] = 8
    d = run_e2e(spec: s2).diff
    assert_equal 'PASS', v(d)['textures_pixels']
    assert_equal 'FAIL', v(d)['textures_colorize']
    assert_equal ['colorize_output_unavailable'], fields(d, 'textures_colorize')
  end

  def test_material_and_tag_table_mismatches
    d = run_e2e(decoded_mutator: ->(h) { h[:materials][1][:color][:r] = 11 }).diff
    assert_only_fail(d, 'materials')
    assert_equal ['color'], fields(d, 'materials')
    d = run_e2e(decoded_mutator: ->(h) { h[:tags][1][:visible] = true }).diff
    assert_only_fail(d, 'tags')
    assert_equal ['visible'], fields(d, 'tags')
    d = run_e2e(decoded_mutator: ->(h) { h[:materials][1][:name] = 'Paint2' }).diff
    assert_equal 'FAIL', v(d)['materials']
    assert_include fields(d, 'materials'), 'presence'
  end

  def test_unused_material_is_compared
    spec = MTFixture.spec
    spec[:materials] << { name: 'Unused', color: [1, 2, 3, 255], opacity: 1.0, type: 0, texture: nil }
    assert_only_fail(run_e2e(spec: spec).diff)
  end

  def test_exclusions_and_disclosures_are_reported
    d = run_e2e(model_mutator: lambda { |m|
      t = Sketchup::Text.new
      t.text = 'orphan'
      t.point = nil
      m.entities << t
    }).diff
    assert_only_fail(d)
    ex = d[:excluded].find { |e| e[:scope] == 'text_without_point' }
    assert_equal 1, ex[:skpCount]
    assert_equal 0, d[:disclosures][:uv_q0_vertices]
    assert_equal 0, d[:disclosures][:non_triangle_polygons]
    assert d[:excluded].any? { |e| e[:scope] == 'edge_materials' }
  end
end
