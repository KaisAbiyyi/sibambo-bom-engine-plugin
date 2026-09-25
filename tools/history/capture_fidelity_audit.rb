# frozen_string_literal: true

# Independent, read-only comparison of an existing SketchUp native-reference
# capture with a decoded BOMC. This is a diagnostic, not a certification oracle:
# older v1 references lack per-loop UVQ and the collector omits some entity types.
require 'json'
require 'digest'

module CaptureFidelityAudit
  # Diagnostic bucket, not a proof of max coordinate error. Exact tolerances
  # require an ID/loop mapping and direct numeric comparisons.
  POSITION_STEP_M = 0.000000001
  VECTOR_STEP = 0.00001
  CAMERA_STEP_M = 0.00001
  NUMERIC_POSITION_TOLERANCE_M = 0.00000001
  MAX_NUMERIC_FACES = 100_000

  module_function

  def verify_provenance(native_path:, bomc_path:)
    native = File.expand_path(native_path)
    bomc = File.expand_path(bomc_path)
    return { status: 'mismatch', reason: 'Inputs are not in one capture session' } unless File.dirname(native).casecmp?(File.dirname(bomc))
    profile = File.basename(bomc, '.bomc')
    return { status: 'mismatch', reason: 'Unknown profile filename' } unless %w[visual research exact].include?(profile)
    status_path = File.join(File.dirname(native), 'session-status.json')
    return { status: 'not_attested', reason: 'No capture session status' } unless File.file?(status_path)
    status = JSON.parse(File.read(status_path))
    record = status.fetch('profiles').fetch(profile)
    source_sha = status.dig('source', 'sha256')
    good = status['status'] == 'captured_pending_certification' && status['ready'] == false &&
      record['export_status'] == 'success' &&
      status.dig('reference', 'sha256') == Digest::SHA256.file(native).hexdigest &&
      record['bomc_sha256'] == Digest::SHA256.file(bomc).hexdigest &&
      (!source_sha || record['source_model_sha256'] == source_sha)
    { status: good ? 'verified' : 'mismatch', profile: profile,
      source_sha256: source_sha, source_tree_sha256: status['source_tree_sha256'],
      preview_build_sha256: status['preview_build_sha256'],
      session_status_sha256: Digest::SHA256.file(status_path).hexdigest }
  rescue StandardError => error
    { status: 'mismatch', reason: "#{error.class}: #{error.message}" }
  end

  def compare(native_path:, decoded:)
    materials = {}
    tags = {}
    definitions = ['root']
    definition_names = { 'root' => 'Model Root' }
    native_scenes = []
    header = footer = nil
    File.foreach(native_path) do |line|
      row = JSON.parse(line)
      case row['kind']
      when 'header' then header = row
      when 'footer' then footer = row
      when 'material'
        raise 'Duplicate native material ID' if materials.key?(row['id'])
        materials[row.fetch('id')] = row
      when 'tag'
        raise 'Duplicate native tag ID' if tags.key?(row['id'])
        tags[row.fetch('id')] = row
      when 'definition'
        definitions << row.fetch('id')
        definition_names[row.fetch('id')] = row.fetch('name')
      when 'scene' then native_scenes << row
      end
    end
    raise 'Incomplete native reference' unless header &&
      %w[t7-native-reference-raw-v1 t7-native-reference-raw-v2].include?(header['schema_version']) &&
      footer && footer['status'] == 'complete'

    source_faces = Hash.new { |hash, key| hash[key] = [] }
    source_visible_faces = Hash.new { |hash, key| hash[key] = [] }
    source_visible_bindings = Hash.new { |hash, key| hash[key] = [] }
    definitions.each { |id| source_faces[id]; source_visible_faces[id]; source_visible_bindings[id] }
    source_count = source_hidden = source_uv_front = source_uv_back = 0
    File.foreach(native_path) do |line|
      row = JSON.parse(line)
      next unless row['kind'] == 'face'
      hidden = row['hidden'] == true
      hidden ? source_hidden += 1 : source_count += 1
      owner = row.fetch('owner')
      raise "Face belongs to unknown definition #{owner}" unless source_faces.key?(owner)
      signature = face_signature(row.fetch('loops').map { |loop| loop.fetch('points_m') }, row.fetch('normal'))
      source_faces[owner] << signature
      source_visible_faces[owner] << signature unless hidden
      source_visible_bindings[owner] << bound_face_signature(signature,
        native_face_binding(row, materials, tags)) unless hidden
      source_uv_front += 1 if material_texture?(materials, row['front_material'])
      source_uv_back += 1 if material_texture?(materials, row['back_material'])
    end

    output_faces = Hash.new { |hash, key| hash[key] = [] }
    output_visible_faces = Hash.new { |hash, key| hash[key] = [] }
    output_visible_bindings = Hash.new { |hash, key| hash[key] = [] }
    Array(decoded.fetch(:definitions)).each_index { |index| output_faces[index]; output_visible_faces[index]; output_visible_bindings[index] }
    output_count = output_hidden = output_uv_front = output_uv_back = malformed_uv = 0
    Array(decoded.fetch(:meshes)).each do |mesh|
      definition = mesh.fetch(:definition)
      raise 'Mesh belongs to unknown definition' unless output_faces.key?(definition)
      positions = mesh.fetch(:positions)
      mesh.fetch(:faces).each do |face|
        output_count += 1
        loops = [face.fetch(:outer), *face.fetch(:holes)].map do |indices|
          indices.map do |index|
            point = positions[index * 3, 3]
            raise 'Face references missing position' unless point && point.length == 3
            point
          end
        end
        signature = face_signature(loops, face.fetch(:normal))
        output_faces[definition] << signature
        if face[:hidden]
          output_hidden += 1
        else
          output_visible_faces[definition] << signature
          output_visible_bindings[definition] << bound_face_signature(signature,
            output_face_binding(face, decoded.fetch(:materials), decoded.fetch(:tags)))
        end
        output_uv_front += 1 if face[:has_front_uv]
        output_uv_back += 1 if face[:has_back_uv]
        [:front, :back].each do |side|
          next unless face[("has_#{side}_uv").to_sym]
          uv = face[:uv] || {}
          malformed_uv += 1 unless Array(uv[("#{side}_outer").to_sym]).length == face[:outer].length &&
            Array(uv[("#{side}_holes").to_sym]).map(&:length) == face[:holes].map(&:length)
        end
      end
    end

    source_groups = group_signatures(source_faces)
    output_groups = group_signatures(output_faces)
    source_visible_groups = group_signatures(source_visible_faces)
    output_visible_groups = group_signatures(output_visible_faces)
    source_binding_groups = group_signatures(source_visible_bindings)
    output_binding_groups = group_signatures(output_visible_bindings)
    numeric = { matched_groups: 0, max_abs_position_error_m: 0.0, status: 'not_needed' }
    if source_count == output_count - output_hidden && source_visible_groups != output_visible_groups
      numeric = resolve_groups(native_path, source_visible_faces, output_visible_faces, decoded)
    end
    visible_ok = source_count == output_count - output_hidden &&
      (source_visible_groups == output_visible_groups || numeric[:status] == 'matched')
    all_numeric = { matched_groups: 0, max_abs_position_error_m: 0.0, status: 'not_needed' }
    if source_count + source_hidden == output_count && source_hidden == output_hidden && source_groups != output_groups
      all_numeric = resolve_groups(native_path, source_faces, output_faces, decoded, include_hidden: true) do |source, output|
        (source['hidden'] == true) == (output[:hidden] == true)
      end
    end
    all_ok = source_count + source_hidden == output_count && source_hidden == output_hidden && visible_ok &&
      (source_groups == output_groups || all_numeric[:status] == 'matched')
    binding_numeric = { matched_groups: 0, status: 'not_needed' }
    if source_count == output_count - output_hidden && source_binding_groups != output_binding_groups
      binding_numeric = resolve_groups(native_path, source_visible_bindings, output_visible_bindings, decoded) do |source, output|
        native_face_binding(source, materials, tags) ==
          output_face_binding(output, decoded.fetch(:materials), decoded.fetch(:tags))
      end
    end
    bindings_ok = source_count == output_count - output_hidden &&
      (source_binding_groups == output_binding_groups || binding_numeric[:status] == 'matched')
    visible_source_diffs = visible_ok ? [] : multiset_difference(source_visible_groups, output_visible_groups)
    visible_output_diffs = visible_ok ? [] : multiset_difference(output_visible_groups, source_visible_groups)
    binding_source_diffs = bindings_ok ? [] : multiset_difference(source_binding_groups, output_binding_groups)
    binding_output_diffs = bindings_ok ? [] : multiset_difference(output_binding_groups, source_binding_groups)
    native_materials = materials.values.map do |row|
      [row.fetch('name'), row.fetch('color')[0, 4].map(&:to_i), quantize(row.fetch('alpha'), 0.0001), !row['texture'].nil?]
    end.sort
    output_materials = decoded.fetch(:materials).map do |row|
      color = row.fetch(:color)
      [row.fetch(:name), [:r, :g, :b, :a].map { |channel| color.fetch(channel).to_i },
        quantize(row.fetch(:opacity), 0.0001), !row[:texture].nil?]
    end.sort
    native_tags = tags.values.map { |row| [row.fetch('name'), row.fetch('visible')] }.sort
    output_tags = decoded.fetch(:tags).map { |row| [row.fetch(:name), row.fetch(:visible)] }.sort
    source_cameras = native_scenes.map { |row| [row['name'], row['eye_m'], row['target_m'], row['up']] }
    output_cameras = decoded.fetch(:scenes).reject do |row|
      binding = row[:source_binding] || {}
      (row[:id] == 'scene:doc:current_view' && binding[:provider] == 'sketchup' &&
        binding[:persistent_id] == 'current_view') ||
        (row[:source] == 'legacy-synthetic' && binding[:provider] == 'bomc' &&
          binding[:persistent_id] == 'legacy_synthetic')
    end.map do |row|
      camera = row.fetch(:camera)
      [row[:name], camera[:eye_m], camera[:target_m], camera[:up]]
    end
    missing_source_scenes, missing_output_scenes = scene_differences(source_cameras, output_cameras)
    uv_structure_ok = source_uv_front == output_uv_front && source_uv_back == output_uv_back && malformed_uv.zero?

    {
      ready: false,
      scope: 'read-only local-geometry/material/scene diagnostic; not T7/T8 certification',
      geometry: { status: all_ok ? 'matched' : (visible_ok ? 'partial_hidden' : 'mismatch'),
        visible_status: visible_ok ? 'matched' : 'mismatch',
        all_faces_status: all_ok ? 'matched' : 'mismatch', bucket_m: POSITION_STEP_M,
        source_visible_faces: source_count, source_hidden_faces: source_hidden,
        output_faces: output_count, output_hidden_faces: output_hidden,
        source_definitions: source_faces.length, output_definitions: output_faces.length,
        numeric_resolved_groups: numeric[:matched_groups], numeric_fallback_status: numeric[:status],
        max_abs_position_error_m: numeric[:max_abs_position_error_m],
        all_numeric_resolved_groups: all_numeric[:matched_groups], all_numeric_fallback_status: all_numeric[:status],
        all_max_abs_position_error_m: all_numeric[:max_abs_position_error_m],
        direct_numeric_tolerance_m: NUMERIC_POSITION_TOLERANCE_M,
        unmatched_source_visible_groups: visible_source_diffs,
        unmatched_output_visible_groups: visible_output_diffs,
        source_visible_group_examples: unmatched_group_examples(source_visible_faces, definition_names,
          visible_source_diffs),
        output_visible_group_examples: unmatched_group_examples(output_visible_faces,
          decoded.fetch(:definitions).each_with_index.each_with_object({}) { |(row, index), names| names[index] = row[:name] },
          visible_output_diffs),
        unmatched_source_groups: all_ok ? [] : multiset_difference(source_groups, output_groups),
        unmatched_output_groups: all_ok ? [] : multiset_difference(output_groups, source_groups) },
      materials: { status: native_materials == output_materials ? 'matched' : 'mismatch',
        source_count: native_materials.length, output_count: output_materials.length,
        source_only: (native_materials - output_materials).first(8), output_only: (output_materials - native_materials).first(8) },
      face_bindings: { status: bindings_ok ? 'matched' : 'mismatch', scope: 'visible_definition_faces',
        numeric_fallback_status: binding_numeric[:status], numeric_resolved_groups: binding_numeric[:matched_groups],
        source_only_groups: binding_source_diffs, output_only_groups: binding_output_diffs },
      tags: { status: native_tags == output_tags ? 'matched' : 'mismatch',
        source_count: native_tags.length, output_count: output_tags.length },
      uv_structure: { status: uv_structure_ok ? 'coverage_only' : 'mismatch',
        source_front_textured_faces: source_uv_front, output_front_uv_faces: output_uv_front,
        source_back_textured_faces: source_uv_back, output_back_uv_faces: output_uv_back,
        malformed_output_uv_faces: malformed_uv },
      uv_values: { status: 'unverifiable', reason: header['schema_version'].end_with?('v1') ?
        'Native v1 capture uses mesh.uv_at, not per-loop UVHelper.' :
        'Native v2 per-loop UVQ requires a hash-bound face correspondence for numeric comparison.' },
      scenes: { status: missing_source_scenes.empty? && missing_output_scenes.empty? ? 'matched' : 'mismatch',
        source_pages: source_cameras.length, output_pages: output_cameras.length,
        source_only: missing_source_scenes.first(8), output_only: missing_output_scenes.first(8) },
      unsupported_native_entities: footer.dig('counts', 'uncollected_entity') || 0
    }
  end

  # Compare independently captured v2 UVQ and native instance matrices against
  # Exact's decoded values. The producer sidecar is only an index; each source
  # ID, owner, geometry and file hash is independently checked before use.
  def compare_exact_correspondence(native_path:, bomc_path:, correspondence_path:, decoded:)
    unknown = { ready: false, correspondence: { status: 'mismatch' },
      uv_values: { status: 'unverifiable' }, instance_transforms: { status: 'unverifiable' } }
    provenance = verify_provenance(native_path: native_path, bomc_path: bomc_path)
    raise "Capture provenance #{provenance[:status]}" unless provenance[:status] == 'verified' && provenance[:profile] == 'exact'
    raise 'Decoded output is not Exact profile' unless decoded.dig(:encoding_contract, :profile).to_s == 'exact'
    status_path = File.join(File.dirname(File.expand_path(native_path)), 'session-status.json')
    status = JSON.parse(File.read(status_path))
    descriptor = status.fetch('profiles').fetch('exact').fetch('source_correspondence')
    raise 'Correspondence is outside the capture session' unless
      File.dirname(File.realpath(correspondence_path)).casecmp?(File.dirname(File.realpath(native_path)))
    raise 'Correspondence path differs from attestation' unless
      File.realpath(descriptor.fetch('path')).casecmp?(File.realpath(correspondence_path))
    raise 'Correspondence hash differs from attestation' unless
      descriptor.fetch('sha256') == Digest::SHA256.file(correspondence_path).hexdigest
    sidecar = JSON.parse(File.read(correspondence_path))
    raise 'Correspondence schema or state invalid' unless sidecar['schema'] == 'bomc-source-correspondence-v1' &&
      descriptor['schema'] == sidecar['schema'] && sidecar['ready'] == false
    raise 'Correspondence source/BOMC hash mismatch' unless
      sidecar['source_sha256'] == status.dig('source', 'sha256') &&
      sidecar['bomc_sha256'] == Digest::SHA256.file(bomc_path).hexdigest

    native_faces = {}
    native_instances = {}
    native_definitions = []
    header = footer = last_kind = nil
    File.foreach(native_path) do |line|
      row = JSON.parse(line)
      last_kind = row['kind']
      case last_kind
      when 'header'
        raise 'Duplicate native header' if header
        header = row
      when 'footer'
        raise 'Duplicate native footer' if footer
        footer = row
      when 'face', 'instance'
        target = last_kind == 'face' ? native_faces : native_instances
        id = row.fetch('id')
        raise "Duplicate or missing native #{last_kind} ID" if id.nil? || target.key?(id)
        target[id] = row
      when 'definition'
        native_definitions << row.fetch('id')
      end
    end
    raise 'Correspondence requires complete native v2 reference' unless
      header && header['schema_version'] == 't7-native-reference-raw-v2' &&
      footer && last_kind == 'footer' && footer['status'] == 'complete'
    definition_map = indexed_correspondence(sidecar.fetch('definitions'), decoded.fetch(:definitions).length, 'definition')
    face_map = indexed_face_correspondence(sidecar.fetch('faces'), decoded.fetch(:meshes))
    instance_map = indexed_correspondence(sidecar.fetch('instances'), decoded.fetch(:instances).length, 'instance')
    sidecar.fetch('definitions').each do |row|
      output_kind = decoded.fetch(:definitions).fetch(row.fetch('index')).fetch(:kind)
      expected = row['kind'] == 'root' ? 'model_definition' : row['kind']
      raise 'Definition sidecar kind mismatch' unless expected == output_kind
    end
    sidecar.fetch('instances').each do |row|
      raise 'Instance sidecar kind mismatch' unless
        row.fetch('kind') == decoded.fetch(:instances).fetch(row.fetch('index')).fetch(:kind)
    end
    raise 'Native/decoded face correspondence incomplete' unless native_faces.keys.sort == face_map.keys.sort
    supported_nodes = instance_map.select { |_id, row| %w[group_instance component_instance].include?(row['kind']) }
    raise 'Native/decoded instance correspondence incomplete' unless native_instances.keys.sort == supported_nodes.keys.sort
    raise 'Root definition correspondence missing' unless definition_map['root'] == 0
    raise 'Definition correspondence incomplete' unless (['root'] + native_definitions).sort == definition_map.keys.sort

    uv_compared = 0
    uv_max = 0.0
    uv_reason = nil
    native_faces.each do |id, source|
      mapping = face_map.fetch(id)
      mesh = decoded.fetch(:meshes).fetch(mapping.fetch('mesh'))
      face = mesh.fetch(:faces).fetch(mapping.fetch('face'))
      owner_index = definition_map.fetch(source.fetch('owner'))
      raise "Face #{id} owner mismatch" unless mapping.fetch('definition') == owner_index && mesh.fetch(:definition) == owner_index
      raise "Face #{id} hidden state mismatch" unless source.fetch('hidden') == face.fetch(:hidden)
      raise "Face #{id} normal mismatch" unless vector_near?(source.fetch('normal'), face.fetch(:normal), VECTOR_STEP)
      loops = paired_face_loops(source.fetch('loops'), face, mesh.fetch(:positions))
      raise "Face #{id} geometry mismatch" unless loops
      uvq = source.fetch('loop_uvq')
      case uvq.fetch('status')
      when 'unavailable'
        uv_reason ||= "Native UVQ unavailable for face #{id}: #{uvq['reason']}"
      when 'not_textured'
        raise "Face #{id} unexpectedly has output UV" if face[:has_front_uv] || face[:has_back_uv]
      when 'measured'
        [:front, :back].each do |side|
          key = side.to_s
          source_outer = uvq["#{key}_outer"]
          output_present = face[("has_#{key}_uv").to_sym]
          raise "Face #{id} #{side} UV coverage mismatch" unless !source_outer.nil? == !!output_present
          next unless source_outer
          source_loops = [source_outer, *uvq.fetch("#{key}_holes")]
          output_uv = face.fetch(:uv)
          output_loops = [output_uv.fetch(("#{key}_outer").to_sym),
                          *output_uv.fetch(("#{key}_holes").to_sym)]
          raise "Face #{id} #{side} UV loop count mismatch" unless source_loops.length == output_loops.length
          loops.each do |source_index, output_index, rotation|
            input = source_loops.fetch(source_index)
            output = output_loops.fetch(output_index)
            raise "Face #{id} #{side} UV vertex count mismatch" unless input.length == output.length
            input.each_with_index do |uvq_triplet, vertex_index|
              normalized = normalize_uvq(uvq_triplet)
              candidate = output.fetch((vertex_index + rotation) % output.length)
              raise "Face #{id} #{side} UV value invalid" unless finite_vector?(candidate, 2)
              normalized.zip(candidate).each do |left, right|
                delta = (left - right).abs
                raise "Face #{id} #{side} UV value mismatch" if delta > NUMERIC_POSITION_TOLERANCE_M
                uv_max = [uv_max, delta].max
                uv_compared += 1
              end
            end
          end
        end
      else
        raise "Face #{id} unknown native UVQ status"
      end
    end

    transform_compared = 0
    transform_max = 0.0
    native_instances.each do |id, source|
      mapping = supported_nodes.fetch(id)
      output = decoded.fetch(:instances).fetch(mapping.fetch('index'))
      raise "Instance #{id} kind mismatch" unless mapping.fetch('kind') == output.fetch(:kind)
      expected_type = mapping['kind'] == 'group_instance' ? 'Group' : 'ComponentInstance'
      raise "Instance #{id} native type mismatch" unless source.fetch('type') == expected_type
      raise "Instance #{id} definition mismatch" unless output.fetch(:definition) == definition_map.fetch(source.fetch('definition'))
      raise "Instance #{id} owner mismatch" unless output.fetch(:owner_definition) == definition_map.fetch(source.fetch('owner'))
      raise "Instance #{id} hidden state mismatch" if source.fetch('hidden') && output.fetch(:visible)
      original = source.fetch('transform')
      converted = original.each_with_index.map { |number, index| [12, 13, 14].include?(index) ? number * 0.0254 : number }
      actual = decoded.fetch(:transforms).fetch(output.fetch(:transform))
      raise "Instance #{id} matrix shape invalid" unless finite_vector?(converted, 16) && finite_vector?(actual, 16)
      converted.zip(actual).each do |left, right|
        delta = (left - right).abs
        raise "Instance #{id} transform mismatch" if delta > NUMERIC_POSITION_TOLERANCE_M
        transform_max = [transform_max, delta].max
        transform_compared += 1
      end
    end

    { ready: false,
      correspondence: { status: 'verified', source_faces: native_faces.length,
        source_instances: native_instances.length, sidecar_sha256: descriptor.fetch('sha256') },
      uv_values: { status: uv_reason ? 'unverifiable' : (uv_compared.zero? ? 'not_applicable' : 'matched'), compared_scalars: uv_compared,
        max_abs_error: uv_max, tolerance: NUMERIC_POSITION_TOLERANCE_M, reason: uv_reason },
      instance_transforms: { status: transform_compared.zero? ? 'not_applicable' : 'matched', compared_scalars: transform_compared,
        max_abs_error: transform_max, tolerance: NUMERIC_POSITION_TOLERANCE_M } }
  rescue StandardError => error
    unknown[:correspondence][:reason] = "#{error.class}: #{error.message}"
    if error.message.match?(/\AFace \S+ (?:front|back) UV|\AInvalid native UVQ|\AInstance \S+ transform/)
      unknown[:correspondence][:status] = 'verified' if defined?(sidecar) && sidecar
      key = error.message.start_with?('Instance') ? :instance_transforms : :uv_values
      unknown[key] = { status: 'mismatch', reason: error.message }
    end
    unknown
  end

  def indexed_correspondence(rows, output_count, kind)
    raise "Incomplete #{kind} sidecar table" unless rows.length == output_count
    ids = {}
    used = {}
    rows.each do |row|
      index = row.fetch('index')
      raise "Invalid #{kind} sidecar index" unless index.is_a?(Integer) && index.between?(0, output_count - 1) && !used[index]
      used[index] = true
      id = row['source_id']
      next if id.nil? && kind == 'instance' && row['kind'] == 'root'
      raise "Duplicate or missing #{kind} sidecar ID" if id.nil? || ids.key?(id)
      ids[id] = row if kind == 'instance'
      ids[id] = index if kind == 'definition'
    end
    ids
  end

  def indexed_face_correspondence(rows, meshes)
    expected = meshes.sum { |mesh| mesh.fetch(:faces).length }
    raise 'Incomplete face sidecar table' unless rows.length == expected
    ids = {}
    used = {}
    rows.each do |row|
      mesh_index = row.fetch('mesh')
      face_index = row.fetch('face')
      raise 'Invalid face sidecar index' unless mesh_index.is_a?(Integer) && mesh_index.between?(0, meshes.length - 1) &&
        face_index.is_a?(Integer) && face_index.between?(0, meshes.fetch(mesh_index).fetch(:faces).length - 1)
      key = [mesh_index, face_index]
      id = row['source_id']
      raise 'Duplicate or missing face sidecar ID' if id.nil? || ids.key?(id) || used[key]
      raise 'Face sidecar definition mismatch' unless row['definition'] == meshes.fetch(mesh_index)[:definition]
      ids[id] = row
      used[key] = true
    end
    ids
  end

  def paired_face_loops(source_loops, face, positions)
    outer = source_loops.find { |row| row['outer'] == true }
    return nil unless outer && source_loops.count { |row| row['outer'] == true } == 1
    native = [outer, *source_loops.reject { |row| row['outer'] == true }]
    output_indices = [face.fetch(:outer), *face.fetch(:holes)]
    return nil unless native.length == output_indices.length
    output = output_indices.map { |loop| loop.map { |index| positions[index * 3, 3] } }
    used = {}
    native.each_with_index.map do |source, source_index|
      candidates = source_index.zero? ? [0] : (1...output.length).to_a
      match = candidates.each_with_object([]) do |candidate_index, matches|
        next if used[candidate_index]
        rotation = loop_rotation(source.fetch('points_m'), output[candidate_index])
        matches << [source_index, candidate_index, rotation] unless rotation.nil?
      end.first
      return nil unless match
      used[match[1]] = true
      match
    end
  end

  def loop_rotation(left, right)
    return nil unless right && left.length == right.length
    left.length.times.find do |rotation|
      left.each_with_index.all? do |point, index|
        vector_near?(point, right[(index + rotation) % right.length], NUMERIC_POSITION_TOLERANCE_M)
      end
    end
  end

  def normalize_uvq(value)
    raise 'Invalid native UVQ' unless finite_vector?(value, 3)
    value[2].zero? ? [0.0, 0.0] : [value[0].to_f / value[2], value[1].to_f / value[2]]
  end

  def finite_vector?(value, size)
    value.is_a?(Array) && value.length == size && value.all? { |number| number.is_a?(Numeric) && number.finite? }
  end

  def material_texture?(materials, id)
    return false if id.nil?
    row = materials[id]
    raise "Unknown native material #{id}" unless row
    !row['texture'].nil?
  end

  def native_face_binding(face, materials, tags)
    [face['front_material'], face['back_material']].map do |id|
      id.nil? ? nil : native_material_identity(materials.fetch(id))
    end + [face['tag'].nil? ? nil : native_tag_identity(tags.fetch(face['tag']))]
  end

  def output_face_binding(face, materials, tags)
    [face[:front_material], face[:back_material]].map do |index|
      index.nil? ? nil : output_material_identity(materials.fetch(index))
    end + [face[:tag].nil? ? nil : output_tag_identity(tags.fetch(face[:tag]))]
  end

  def native_material_identity(row)
    [row.fetch('name'), row.fetch('color').map(&:to_i), quantize(row.fetch('alpha'), 0.0001), !row['texture'].nil?]
  end

  def output_material_identity(row)
    color = row.fetch(:color)
    [row.fetch(:name), [:r, :g, :b, :a].map { |channel| color.fetch(channel).to_i },
      quantize(row.fetch(:opacity), 0.0001), !row[:texture].nil?]
  end

  def native_tag_identity(row)
    [row.fetch('name'), row.fetch('visible')]
  end

  def output_tag_identity(row)
    [row.fetch(:name), row.fetch(:visible)]
  end

  def bound_face_signature(geometry_signature, binding)
    Digest::SHA256.hexdigest(JSON.generate([geometry_signature, binding]))
  end

  def quantize(value, step)
    raise 'Non-finite comparison value' unless value.is_a?(Numeric) && value.finite?
    (value.to_f / step).round
  end

  def canonical_loop(points)
    raise 'Face loop has too few points' if points.length < 3
    # SketchUp emits full floats; Exact stores them at nine decimal places.
    # Use the wire precision as a diagnostic bucket. A mismatch at the bucket
    # boundary is inconclusive until directly measured, not a fidelity verdict.
    vertices = points.map do |point|
      point.map do |coordinate|
        raise 'Non-finite face coordinate' unless coordinate.is_a?(Numeric) && coordinate.finite?
        coordinate.to_f.round(9)
      end
    end
    raise 'Face loop coordinate shape' unless vertices.all? { |point| point.length == 3 }
    vertices.each_index.map { |index| vertices.rotate(index) }.min
  end

  def face_signature(loops, normal)
    raise 'Face has no outer loop' if loops.empty?
    outer = canonical_loop(loops.first)
    holes = loops.drop(1).map { |loop| canonical_loop(loop) }.sort
    normalized = normal.map { |coordinate| quantize(coordinate, VECTOR_STEP) }
    Digest::SHA256.hexdigest(JSON.generate([outer, holes, normalized]))
  end

  def group_signatures(groups)
    groups.values.map { |faces| Digest::SHA256.hexdigest(faces.sort.join("\n")) }.sort
  end

  def unmatched_owners(groups, other)
    remaining = other.values.each_with_object(Hash.new(0)) do |faces, counts|
      counts[Digest::SHA256.hexdigest(faces.sort.join("\n"))] += 1
    end
    groups.each_with_object([]) do |(owner, faces), owners|
      digest = Digest::SHA256.hexdigest(faces.sort.join("\n"))
      remaining[digest] > 0 ? remaining[digest] -= 1 : owners << owner
    end
  end

  def resolve_groups(native_path, source_groups, output_groups, decoded, include_hidden: false, &face_check)
    source_owners = unmatched_owners(source_groups, output_groups)
    output_owners = unmatched_owners(output_groups, source_groups)
    faces_to_check = source_owners.sum { |owner| source_groups.fetch(owner).length }
    return { status: 'resource_limit', matched_groups: 0, max_abs_position_error_m: nil } if faces_to_check > MAX_NUMERIC_FACES
    return { status: 'mismatch', matched_groups: 0, max_abs_position_error_m: nil } unless source_owners.length == output_owners.length

    wanted = source_owners.each_with_object({}) { |owner, ids| ids[owner] = true }
    source_rows = Hash.new { |hash, key| hash[key] = [] }
    File.foreach(native_path) do |line|
      row = JSON.parse(line)
      source_rows[row['owner']] << row if row['kind'] == 'face' &&
        (include_hidden || row['hidden'] != true) && wanted[row['owner']]
    end
    matched = 0
    maximum = 0.0
    source_owners.each do |owner|
      rows = source_rows.fetch(owner, [])
      candidate = output_owners.find do |index|
        next false unless output_groups.fetch(index).length == rows.length
        definition = decoded.fetch(:definitions).fetch(index)
        mesh = definition[:mesh].nil? ? nil : decoded.fetch(:meshes).fetch(definition[:mesh])
        next false unless mesh
        faces = include_hidden ? mesh.fetch(:faces) : mesh.fetch(:faces).reject { |face| face[:hidden] }
        delta = numeric_faces_delta(rows, faces, mesh.fetch(:positions), &face_check)
        next false if delta.nil?
        maximum = [maximum, delta].max
        true
      end
      return { status: 'mismatch', matched_groups: matched, max_abs_position_error_m: maximum } unless candidate
      output_owners.delete(candidate)
      matched += 1
    end
    { status: output_owners.empty? ? 'matched' : 'mismatch', matched_groups: matched,
      max_abs_position_error_m: maximum }
  end

  def numeric_faces_delta(source_rows, output_faces, positions, &face_check)
    return nil unless source_rows.length == output_faces.length
    maximum = 0.0
    source_rows.zip(output_faces).each do |source, output|
      return nil if face_check && !face_check.call(source, output)
      return nil unless vector_near?(source.fetch('normal'), output.fetch(:normal), VECTOR_STEP)
      source_loops = source.fetch('loops').map { |row| row.fetch('points_m') }
      output_loops = [output.fetch(:outer), *output.fetch(:holes)].map do |loop|
        loop.map { |index| positions[index * 3, 3] }
      end
      return nil unless source_loops.length == output_loops.length
      source_loops.zip(output_loops).each do |left, right|
        delta = loop_delta(left, right)
        return nil if delta.nil?
        maximum = [maximum, delta].max
      end
    end
    maximum
  end

  def loop_delta(left, right)
    return nil unless left.length == right.length
    left.length.times do |rotation|
      next unless vector_near?(left.first, right[rotation], NUMERIC_POSITION_TOLERANCE_M)
      maximum = 0.0
      matched = left.each_with_index.all? do |point, index|
        candidate = right[(index + rotation) % right.length]
        next false unless vector_near?(point, candidate, NUMERIC_POSITION_TOLERANCE_M)
        maximum = [maximum, *point.zip(candidate).map { |a, b| (a - b).abs }].max
        true
      end
      return maximum if matched
    end
    nil
  end

  def unmatched_group_examples(groups, names, signatures)
    wanted = signatures.each_with_object(Hash.new(0)) { |value, counts| counts[value] += 1 }
    groups.each_with_object([]) do |(owner, faces), examples|
      signature = Digest::SHA256.hexdigest(faces.sort.join("\n"))
      next if wanted[signature] <= 0
      examples << { name: names[owner], faces: faces.length, digest: signature }
      wanted[signature] -= 1
    end
  end

  def multiset_difference(left, right)
    remaining = right.each_with_object(Hash.new(0)) { |value, counts| counts[value] += 1 }
    left.each_with_object([]) do |value, difference|
      remaining[value] > 0 ? remaining[value] -= 1 : difference << value
    end.first(8)
  end

  def vector_near?(left, right, tolerance)
    left.is_a?(Array) && right.is_a?(Array) && left.length == 3 && right.length == 3 &&
      left.zip(right).all? { |a, b| a.is_a?(Numeric) && b.is_a?(Numeric) && a.finite? && b.finite? && (a - b).abs <= tolerance }
  end

  def scene_differences(source, output)
    remaining = output.dup
    source_only = []
    source.each do |row|
      index = remaining.index do |candidate|
        row[0] == candidate[0] && vector_near?(row[1], candidate[1], CAMERA_STEP_M) &&
          vector_near?(row[2], candidate[2], CAMERA_STEP_M) && vector_near?(row[3], candidate[3], VECTOR_STEP)
      end
      index ? remaining.delete_at(index) : source_only << row
    end
    [source_only, remaining]
  end
end

if $PROGRAM_NAME == __FILE__
  require_relative '../../bom_engine/bomc_decoder'
  native_path, bomc_path, correspondence_path = ARGV
  abort 'Usage: ruby capture_fidelity_audit.rb <native-reference.jsonl> <profile.bomc> [source-correspondence-exact.json]' unless
    native_path && bomc_path && (2..3).include?(ARGV.length)
  decoded = BOMEngine::BOMCDecoder.decode(File.binread(bomc_path), allow_jpeg_color_map: true)
  report = CaptureFidelityAudit.compare(native_path: native_path, decoded: decoded)
  report[:inputs] = { native_sha256: Digest::SHA256.file(native_path).hexdigest,
    bomc_sha256: Digest::SHA256.file(bomc_path).hexdigest, profile: decoded.dig(:encoding_contract, :profile) }
  report[:provenance] = CaptureFidelityAudit.verify_provenance(native_path: native_path, bomc_path: bomc_path)
  if report.dig(:provenance, :profile) == 'exact'
    correspondence_path ||= File.join(File.dirname(native_path), 'source-correspondence-exact.json')
    report.merge!(CaptureFidelityAudit.compare_exact_correspondence(native_path: native_path,
      bomc_path: bomc_path, correspondence_path: correspondence_path, decoded: decoded))
  end
  puts JSON.pretty_generate(report)
  exact_checks = report.dig(:provenance, :profile) != 'exact' ||
    (report.dig(:correspondence, :status) == 'verified' &&
      %w[matched not_applicable].include?(report.dig(:uv_values, :status)) &&
      %w[matched not_applicable].include?(report.dig(:instance_transforms, :status)))
  exit(report.dig(:provenance, :status) == 'verified' && exact_checks &&
    [:geometry, :materials, :face_bindings, :tags, :uv_structure, :scenes].all? { |key| report.dig(key, :status) == 'matched' ||
      (key == :uv_structure && report.dig(key, :status) == 'coverage_only') } ? 0 : 2)
end
