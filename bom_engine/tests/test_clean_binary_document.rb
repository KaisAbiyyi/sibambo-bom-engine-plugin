# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require 'zlib'

require_relative '../clean_analysis/binary/document_encoder'
require_relative '../clean_analysis/binary/reference_decoder'
require_relative '../clean_analysis/clean_package'

class CleanBinaryDocumentTest < Minitest::Test
  MAT_RED = 'mat-1111111111111111'.freeze
  MAT_BLUE = 'mat-2222222222222222'.freeze
  DEF_ID = 'definition-1111111111111111'.freeze

  def test_encoder_moves_numeric_geometry_uv_and_transforms_out_of_manifest
    encoded = BOMEngine::CleanAnalysis::Binary::DocumentEncoder.encode(logical_document)
    manifest = encoded.fetch(:manifest)
    json = JSON.generate(manifest)
    root_binary = manifest.dig('binary_tables', 'root_surfaces')
    instance_binary = manifest.dig('binary_tables', 'instances')

    assert_equal 'bom_engine_clean_package', manifest.dig('format', 'identifier')
    assert_equal '1.0.0', manifest.dig('format', 'version')
    assert_equal 'bom_engine_clean_v1', manifest.dig('format', 'logical_identifier')
    refute_includes json, '"outer":[['
    refute_includes json, '"vertices":[['
    refute_includes json, '"transform":['
    refute_includes json, '"uvs":['
    assert_equal 'int32', descriptor_for(manifest, root_binary.dig('positions', 'section')).fetch('component_type')
    assert_equal 'uint16', descriptor_for(manifest, root_binary.dig('loop_vertex_indices', 'section')).fetch('component_type')
    assert_equal 'float32', descriptor_for(manifest, root_binary.dig('uvs', 'section')).fetch('component_type')
    transform_descriptor = descriptor_for(manifest, instance_binary.dig('transforms', 'section'))
    assert_equal 'float64', transform_descriptor.fetch('component_type')
    assert_equal 12, transform_descriptor.fetch('component_count')
    assert_equal 2, transform_descriptor.fetch('count')
    assert_equal logical_document.fetch('diagnostics'), manifest.fetch('diagnostics')
  end

  def test_shared_definition_geometry_is_encoded_once_for_multiple_instances
    encoded = BOMEngine::CleanAnalysis::Binary::DocumentEncoder.encode(logical_document)
    definition = encoded.dig(:manifest, 'definitions', 0)
    position_section = definition.dig('geometry', 'binary', 'positions', 'section')
    descriptor = descriptor_for(encoded.fetch(:manifest), position_section)

    assert_equal 8, descriptor.fetch('count')
    assert_equal 2, encoded.dig(:manifest, 'instances').length
    assert_equal 1, encoded.fetch(:statistics).fetch(:definition_geometry_count)
  end

  def test_numeric_material_and_definition_references_use_integer_sections
    encoded = BOMEngine::CleanAnalysis::Binary::DocumentEncoder.encode(logical_document)
    manifest = encoded.fetch(:manifest)
    buffers = encoded.fetch(:buffers)

    root_front = unpack_section(manifest, buffers, manifest.dig('binary_tables', 'root_surfaces', 'front_material_indices', 'section'))
    instance_definitions = unpack_section(manifest, buffers, manifest.dig('binary_tables', 'instances', 'definition_indices', 'section'))
    instance_materials = unpack_section(manifest, buffers, manifest.dig('binary_tables', 'instances', 'material_indices', 'section'))

    assert_equal [0], root_front
    assert_equal [0, 0], instance_definitions
    assert_equal [65_535, 1], instance_materials
    refute manifest.fetch('instances').any? { |item| item.key?('definition_id') || item.key?('material_id') }
  end

  def test_reference_decoder_round_trips_all_semantic_and_visual_content
    source = logical_document
    encoded = BOMEngine::CleanAnalysis::Binary::DocumentEncoder.encode(source)
    decoded = BOMEngine::CleanAnalysis::Binary::ReferenceDecoder.decode(
      encoded.fetch(:manifest), encoded.fetch(:buffers)
    )

    assert_equal source.fetch('format'), decoded.fetch('format')
    assert_equal source.fetch('materials'), decoded.fetch('materials')
    assert_equal source.fetch('diagnostics'), decoded.fetch('diagnostics')
    assert_equal source.fetch('components'), decoded.fetch('components')
    assert_equal source.fetch('excluded_objects'), decoded.fetch('excluded_objects')
    assert_document_close source, decoded
    assert_operator maximum_position_error(source, decoded), :<=, 1.0e-6
  end

  def test_clean_package_is_deterministic_and_contains_only_referenced_assets
    source = logical_document
    asset_name = 'assets/tex-' + ('a' * 64) + '.png'
    unused_name = 'assets/tex-' + ('b' * 64) + '.png'
    source.fetch('materials').first['texture'] = { 'asset' => asset_name, 'status' => 'available' }
    assets = { asset_name => "\x89PNG\r\nfixture".b, unused_name => "unused".b }

    Dir.mktmpdir('clean-package') do |directory|
      first = File.join(directory, 'first.cleanpkg')
      second = File.join(directory, 'second.cleanpkg')
      stats = BOMEngine::CleanAnalysis::CleanPackage.write(first, source, assets)
      BOMEngine::CleanAnalysis::CleanPackage.write(second, source, assets)
      entries = read_zip_entries(first)

      assert_equal File.binread(first), File.binread(second)
      assert_equal %w[buffers.bin manifest.json].push(asset_name).sort, entries.keys.sort
      refute entries.key?(unused_name)
      assert_equal 8, entries.fetch('manifest.json').fetch(:method)
      assert_equal 8, entries.fetch('buffers.bin').fetch(:method)
      assert_equal 0, entries.fetch(asset_name).fetch(:method)
      manifest = JSON.parse(entries.fetch('manifest.json').fetch(:bytes))
      refute_match(/data:image|;base64/i, entries.fetch('manifest.json').fetch(:bytes))
      decoded = BOMEngine::CleanAnalysis::Binary::ReferenceDecoder.decode(manifest, entries.fetch('buffers.bin').fetch(:bytes))
      assert_document_close source, decoded
      assert_equal 1, stats.fetch(:unique_texture_count)
      assert_operator stats.fetch(:manifest_bytes), :>, 0
      assert_operator stats.fetch(:buffer_bytes), :>, 0
    end
  end

  def test_uint32_is_selected_when_a_topology_index_exceeds_uint16
    encoder = BOMEngine::CleanAnalysis::Binary::DocumentEncoder.new(logical_document)

    assert_equal 'uint16', encoder.send(:index_type, [0, 65_535])
    assert_equal 'uint32', encoder.send(:index_type, [0, 65_536])
  end

  def test_definition_geometry_buffer_is_constant_through_ten_thousand_instances
    definition_position_bytes = []
    [1, 10, 100, 1_000, 10_000].each do |count|
      document = logical_document
      template = document.fetch('instances').first
      document['instances'] = count.times.map do |index|
        item = Marshal.load(Marshal.dump(template))
        item['id'] = format('instance-%016x', index)
        item
      end
      encoded = BOMEngine::CleanAnalysis::Binary::DocumentEncoder.encode(document)
      manifest = encoded.fetch(:manifest)
      definition_ref = manifest.dig('definitions', 0, 'geometry', 'binary', 'positions', 'section')
      transform_ref = manifest.dig('binary_tables', 'instances', 'transforms', 'section')
      definition_position_bytes << descriptor_for(manifest, definition_ref).fetch('byte_length')
      assert_equal count * 12 * 8, descriptor_for(manifest, transform_ref).fetch('byte_length')
    end

    assert_equal [definition_position_bytes.first] * 5, definition_position_bytes
  end

  private

  def assert_document_close(expected, actual, path = '$')
    case expected
    when Hash
      assert_equal expected.keys.sort, actual.keys.sort, "keys at #{path}"
      expected.each { |key, value| assert_document_close(value, actual.fetch(key), "#{path}.#{key}") }
    when Array
      assert_equal expected.length, actual.length, "length at #{path}"
      expected.each_with_index { |value, index| assert_document_close(value, actual.fetch(index), "#{path}[#{index}]") }
    when Float
      if expected.nan?
        assert actual.nan?, "expected NaN at #{path}"
      else
        assert_in_delta expected, actual, 1.0e-6, "value at #{path}"
      end
    else
      expected.nil? ? assert_nil(actual, "value at #{path}") : assert_equal(expected, actual, "value at #{path}")
    end
  end

  def maximum_position_error(expected, actual)
    pairs = []
    expected.fetch('surfaces').zip(actual.fetch('surfaces')).each do |left, right|
      ([left.fetch('outer')] + left.fetch('holes')).zip([right.fetch('outer')] + right.fetch('holes')).each do |a, b|
        pairs.concat(a.flatten.zip(b.flatten))
      end
    end
    expected.fetch('definitions').zip(actual.fetch('definitions')).each do |left, right|
      pairs.concat(left.dig('geometry', 'vertices').flatten.zip(right.dig('geometry', 'vertices').flatten))
    end
    expected.fetch('visual_edges').zip(actual.fetch('visual_edges')).each do |left, right|
      pairs.concat(left.fetch('vertices').flatten.zip(right.fetch('vertices').flatten))
    end
    pairs.map { |left, right| (left - right).abs }.max || 0.0
  end

  def unpack_section(manifest, buffers, section_index)
    descriptor = descriptor_for(manifest, section_index)
    bytes = buffers.byteslice(descriptor.fetch('byte_offset'), descriptor.fetch('byte_length'))
    directive = {
      'uint16' => 'S<*', 'uint32' => 'L<*', 'int32' => 'l<*',
      'float32' => 'e*', 'float64' => 'E*'
    }.fetch(descriptor.fetch('component_type'))
    bytes.unpack(directive)
  end

  def descriptor_for(manifest, section_index)
    fields = manifest.dig('buffers', 'section_descriptor_fields')
    fields.zip(manifest.dig('buffers', 'sections').fetch(section_index)).to_h
  end

  def read_zip_entries(path)
    archive = File.binread(path)
    entries = {}
    offset = 0
    while archive.byteslice(offset, 4)&.unpack('V')&.first == 0x04034b50
      header = archive.byteslice(offset, 30).unpack('VvvvvvVVVvv')
      method = header.fetch(3)
      compressed_size = header.fetch(7)
      name_size = header.fetch(9)
      extra_size = header.fetch(10)
      name = archive.byteslice(offset + 30, name_size)
      payload_offset = offset + 30 + name_size + extra_size
      payload = archive.byteslice(payload_offset, compressed_size)
      bytes = if method == 8
                inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
                begin
                  inflater.inflate(payload) + inflater.finish
                ensure
                  inflater.close
                end
              else
                payload
              end
      entries[name] = { method: method, bytes: bytes }
      offset = payload_offset + compressed_size
    end
    entries
  end

  def logical_document
    {
      'format' => { 'identifier' => 'bom_engine_clean_v1', 'version' => '1.0.0' },
      'units' => 'm',
      'coordinate_system' => {
        'handedness' => 'right', 'up_axis' => '+Z', 'true_north_xy' => [0.0, 1.0],
        'instance_transform_space' => 'world'
      },
      'model' => { 'bounds' => { 'min' => [0.0, 0.0, 0.0], 'max' => [4.0, 4.0, 3.0] } },
      'materials' => [material(MAT_RED, 'Red'), material(MAT_BLUE, 'Blue')],
      'uvs' => [[-2.0, 3.0], [4.5, 3.0], [4.5, 8.25], [-2.0, 8.25]],
      'surfaces' => [{
        'id' => 'surface-1111111111111111', 'type' => 'floor',
        'outer' => [[0.0, 0.0, 0.0], [4.0, 0.0, 0.0], [4.0, 4.0, 0.0], [0.0, 4.0, 0.0]],
        'holes' => [[[1.0, 1.0, 0.0], [1.0, 2.0, 0.0], [2.0, 2.0, 0.0], [2.0, 1.0, 0.0]]],
        'normal' => [0.0, 0.0, 1.0], 'area_m2' => 15.0, 'source_count' => 1,
        'orientation' => { 'kind' => 'up' }, 'classification' => { 'method' => 'semantic_role' },
        'front_material_id' => MAT_RED,
        'front_uv' => { 'outer' => [0, 1, 2, 3], 'holes' => [[0, 1, 2, 3]] }
      }],
      'definitions' => [{
        'id' => DEF_ID, 'kind' => 'component', 'retention' => 'visual_architectural_detail',
        'geometry' => {
          'coordinate_space' => 'definition_local', 'source_count' => 2, 'edge_source_count' => 1,
          'vertices' => cube_vertices,
          'surfaces' => [
            { 'type' => 'polygon', 'outer' => [0, 1, 2, 3], 'holes' => [], 'front_material_id' => MAT_RED,
              'front_uv' => { 'outer' => [0, 1, 2, 3], 'holes' => [] } },
            { 'type' => 'polygon', 'outer' => [4, 7, 6, 5], 'holes' => [], 'back_material_id' => MAT_BLUE }
          ],
          'edges' => [[0, 4]], 'uvs' => [[-1.0, -1.0], [2.0, -1.0], [2.0, 2.0], [-1.0, 2.0]]
        }
      }],
      'instances' => [
        instance('instance-1111111111111111', rigid_transform, nil),
        instance('instance-2222222222222222', mirrored_non_uniform_transform, MAT_BLUE,
                 parent: 'instance-1111111111111111')
      ],
      'components' => [],
      'visual_edges' => [{ 'id' => 'edge-1111111111111111', 'vertices' => [[0.0, 0.0, 0.0], [0.0, 0.0, 3.0]], 'source_count' => 1 }],
      'excluded_objects' => [],
      'fallback_geometry' => [{
        'id' => 'unresolved-1111111111111111', 'status' => 'unresolved', 'reason' => 'invalid_surface',
        'source_count' => 1, 'area_m2' => 0.5,
        'outer' => [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.5, 0.5, 0.0]], 'holes' => [],
        'validation_issues' => ['outer self-intersects'], 'definition_id' => DEF_ID
      }],
      'diagnostics' => {
        'counts' => { 'architectural_surface_count' => 1, 'instance_count' => 2 },
        'coverage' => { 'analytical' => 1, 'visual_retained' => 2, 'fallback' => 1, 'explicitly_excluded' => 0, 'unaccounted' => 0 },
        'materials' => { 'source' => 2, 'referenced' => 2, 'emitted' => 2, 'unused_emitted' => 0 }
      }
    }
  end

  def material(id, name)
    { 'id' => id, 'name' => name, 'base_color_rgba' => [1.0, 0.0, 0.0, 1.0], 'opacity' => 1.0, 'color_space' => 'srgb', 'texture' => nil }
  end

  def cube_vertices
    [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 1.0, 0.0],
     [0.0, 0.0, 1.0], [1.0, 0.0, 1.0], [1.0, 1.0, 1.0], [0.0, 1.0, 1.0]]
  end

  def instance(id, transform, material_id, parent: nil)
    value = {
      'id' => id, 'definition_id' => DEF_ID, 'name' => 'Shared', 'category' => 'fixture',
      'retention' => 'visual_architectural_detail', 'transform' => transform,
      'transform_kind' => transform.equal?(rigid_transform) ? 'rigid' : 'non_uniform_scale'
    }
    value['material_id'] = material_id if material_id
    value['parent_instance_id'] = parent if parent
    value
  end

  def rigid_transform
    [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 2.0, 3.0, 4.0, 1.0]
  end

  def mirrored_non_uniform_transform
    [-2.0, 0.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.5, 0.0, 5.0, 6.0, 7.0, 1.0]
  end
end
