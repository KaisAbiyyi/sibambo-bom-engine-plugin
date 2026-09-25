# frozen_string_literal: true

require 'json'
require 'digest'
require 'tmpdir'
require_relative '../../tools/history/capture_fidelity_audit'

module CaptureFidelityAuditTest
  module_function

  def assert(condition, message)
    raise "FAIL: #{message}" unless condition
  end

  def source_rows
    [
      { 'kind' => 'header', 'schema_version' => 't7-native-reference-raw-v1' },
      { 'kind' => 'material', 'id' => 'mat-1', 'name' => 'Brick', 'color' => [255, 0, 0, 255], 'alpha' => 1.0, 'texture' => nil },
      { 'kind' => 'material', 'id' => 'mat-2', 'name' => 'Stone', 'color' => [0, 0, 255, 255], 'alpha' => 1.0, 'texture' => nil },
      { 'kind' => 'tag', 'id' => 'tag-1', 'name' => 'Untagged', 'visible' => true },
      { 'kind' => 'face', 'owner' => 'root', 'hidden' => false, 'normal' => [0, 0, 1],
        'loops' => [{ 'outer' => true, 'points_m' => [[0, 0, 0], [1, 0, 0], [0, 1, 0]] }],
        'front_material' => 'mat-1', 'back_material' => nil, 'tag' => 'tag-1' },
      { 'kind' => 'face', 'owner' => 'root', 'hidden' => true, 'normal' => [0, 0, 1],
        'loops' => [{ 'outer' => true, 'points_m' => [[2, 0, 0], [3, 0, 0], [2, 1, 0]] }],
        'front_material' => 'mat-1', 'back_material' => nil, 'tag' => 'tag-1' },
      { 'kind' => 'scene', 'name' => 'Front', 'eye_m' => [1.0000051, 2, 3], 'target_m' => [0, 0, 0], 'up' => [0, 0, 1] },
      { 'kind' => 'footer', 'status' => 'complete' }
    ]
  end

  def decoded
    { materials: [{ name: 'Brick', color: { r: 255, g: 0, b: 0, a: 255 }, opacity: 1.0, texture: nil },
                   { name: 'Stone', color: { r: 0, g: 0, b: 255, a: 255 }, opacity: 1.0, texture: nil }],
      tags: [{ name: 'Untagged', visible: true }],
      definitions: [{ name: 'Model Root', kind: 'model_definition', mesh: 0 }],
      meshes: [{ definition: 0, positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
                 faces: [{ outer: [0, 1, 2], holes: [], normal: [0, 0, 1],
                           front_material: 0, back_material: nil, tag: 0,
                           has_front_uv: false, has_back_uv: false }] }],
      scenes: [{ name: 'Front', camera: { eye_m: [1, 2, 3], target_m: [0, 0, 0], up: [0, 0, 1] } }] }
  end

  def run
    Dir.mktmpdir('fidelity-audit-test-') do |folder|
      native = File.join(folder, 'native.jsonl')
      File.write(native, source_rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

      baseline = CaptureFidelityAudit.compare(native_path: native, decoded: decoded)
      assert(baseline.dig(:geometry, :status) == 'partial_hidden' &&
        baseline.dig(:geometry, :visible_status) == 'matched',
        'visible geometry matches but missing hidden face is not silently certified')
      assert(baseline.dig(:materials, :status) == 'matched', 'material color and name are checked')
      assert(baseline.dig(:face_bindings, :status) == 'matched', 'material and tag bindings follow each visible face')
      assert(baseline.dig(:scenes, :status) == 'matched', 'native page camera uses direct numeric tolerance instead of hash buckets')
      assert(baseline.dig(:uv_values, :status) == 'unverifiable', 'UV values are never silently certified from mismatched APIs')
      assert(baseline[:ready] == false, 'diagnostic evidence alone never promotes a release')

      bomc = File.join(folder, 'exact.bomc')
      File.binwrite(bomc, 'candidate')
      status = { 'status' => 'captured_pending_certification', 'ready' => false,
                 'reference' => { 'sha256' => Digest::SHA256.file(native).hexdigest },
                 'profiles' => { 'exact' => { 'bomc_sha256' => Digest::SHA256.file(bomc).hexdigest,
                                               'export_status' => 'success' } } }
      File.write(File.join(folder, 'session-status.json'), JSON.generate(status))
      assert(CaptureFidelityAudit.verify_provenance(native_path: native, bomc_path: bomc)[:status] == 'verified',
        'only captured files bound by the session hashes receive provenance')
      File.binwrite(bomc, 'tampered')
      assert(CaptureFidelityAudit.verify_provenance(native_path: native, bomc_path: bomc)[:status] == 'mismatch',
        'tampered output invalidates independent audit provenance')

      rounded = decoded
      rounded[:meshes][0][:positions][3] = 1.000000004
      numeric = CaptureFidelityAudit.compare(native_path: native, decoded: rounded)
      assert(numeric.dig(:geometry, :visible_status) == 'matched' &&
        numeric.dig(:geometry, :numeric_resolved_groups) == 1,
        'a wire-bucket collision is resolved by direct coordinate measurement')
      assert(numeric.dig(:geometry, :unmatched_source_visible_groups).empty?,
        'resolved bucket differences are not reported as unmatched geometry')

      moved = decoded
      moved[:meshes][0][:positions][3] = 2
      geometry = CaptureFidelityAudit.compare(native_path: native, decoded: moved)
      assert(geometry.dig(:geometry, :status) == 'mismatch', 'same face count with a moved vertex fails geometry')

      changed = decoded
      changed[:materials][0][:color][:r] = 0
      material = CaptureFidelityAudit.compare(native_path: native, decoded: changed)
      assert(material.dig(:materials, :status) == 'mismatch', 'changed material color fails independently')

      changed = decoded
      changed[:materials][0][:color][:r] = 255
      changed[:meshes][0][:faces][0][:front_material] = 1
      binding = CaptureFidelityAudit.compare(native_path: native, decoded: changed)
      assert(binding.dig(:materials, :status) == 'matched' && binding.dig(:face_bindings, :status) == 'mismatch',
        'face-to-material reassignment fails even when both material definitions are unchanged')

      changed = decoded
      changed[:scenes][0][:camera][:eye_m][0] = 9
      scene = CaptureFidelityAudit.compare(native_path: native, decoded: changed)
      assert(scene.dig(:scenes, :status) == 'mismatch', 'changed scene camera fails independently')

      named_page = source_rows
      named_page.find { |row| row['kind'] == 'scene' }['name'] = 'Current View'
      named_native = File.join(folder, 'named-page.jsonl')
      File.write(named_native, named_page.map { |row| JSON.generate(row) }.join("\n") + "\n")
      named_decoded = decoded
      named_decoded[:scenes][0][:name] = 'Current View'
      named_decoded[:scenes][0][:id] = 'scene:doc:page-1'
      named_decoded[:scenes][0][:source] = 'sketchup-page'
      named_decoded[:scenes][0][:source_binding] = { provider: 'sketchup', persistent_id: 'page-1' }
      named_result = CaptureFidelityAudit.compare(native_path: named_native, decoded: named_decoded)
      assert(named_result.dig(:scenes, :status) == 'matched',
        'a real SketchUp page named Current View must not be mistaken for a synthetic scene')

      no_page_native = File.join(folder, 'no-page.jsonl')
      File.write(no_page_native, source_rows.reject { |row| row['kind'] == 'scene' }
        .map { |row| JSON.generate(row) }.join("\n") + "\n")
      no_page_decoded = decoded
      no_page_decoded[:scenes][0].merge!(
        id: 'scene:doc:current_view', name: 'Current View', source: 'sketchup-page',
        source_binding: { provider: 'sketchup', persistent_id: 'current_view' }
      )
      no_page_result = CaptureFidelityAudit.compare(native_path: no_page_native, decoded: no_page_decoded)
      assert(no_page_result.dig(:scenes, :status) == 'matched' && no_page_result.dig(:scenes, :output_pages).zero?,
        'decoder-labelled current-view fallback must not count as an independently captured page')

      complete = decoded
      complete[:meshes][0][:positions].concat([2, 0, 0, 3.000000004, 0, 0, 2, 1, 0])
      complete[:meshes][0][:faces] << {
        outer: [3, 4, 5], holes: [], normal: [0, 0, 1], hidden: true,
        front_material: 0, back_material: nil, tag: 0,
        has_front_uv: false, has_back_uv: false
      }
      complete_result = CaptureFidelityAudit.compare(native_path: native, decoded: complete)
      assert(complete_result.dig(:geometry, :all_faces_status) == 'matched',
        'a hidden face within direct numeric tolerance is a full geometry match')
      complete[:meshes][0][:positions][12] = 3.001
      moved_hidden = CaptureFidelityAudit.compare(native_path: native, decoded: complete)
      assert(moved_hidden.dig(:geometry, :visible_status) == 'matched' &&
        moved_hidden.dig(:geometry, :all_faces_status) == 'mismatch',
        'a materially moved hidden face must fail while visible geometry remains matched')
    end
    puts 'Capture fidelity audit tests: ALL PASSED'
  end
end

CaptureFidelityAuditTest.run
