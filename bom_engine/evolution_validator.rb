# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'stringio'
require 'zlib'
require_relative 'evolution_document'
require_relative 'evolution_tree_writer'
require_relative 'evolution_stream'
require_relative 'performance_trace'

module BOMEngine
  module EvolutionValidator
    class ValidationError < StandardError; end
    UINT32_NONE = 0xffff_ffff
    module_function

    def validate_file!(path, engine:, expected_profile: nil, source_document: nil, artifact_sha256: nil)
      raise ValidationError, "Evolution candidate missing: #{path}" unless File.file?(path) && File.size(path).positive?
      decoded = PerformanceTrace.stage(:evolution_readback, counts: { bytes: File.size(path) }) { read(path, engine: engine) }
      profile = decoded.fetch(:profile)
      if expected_profile && profile != expected_profile.to_s
        raise ValidationError, "Profile mismatch: expected #{expected_profile}, got #{profile}"
      end
      comparison = source_document ? PerformanceTrace.stage(:evolution_compare) { compare!(source_document, decoded) } : nil
      sha256 = if artifact_sha256
                 normalize_sha256(artifact_sha256)
               else
                 PerformanceTrace.stage(:artifact_hash, counts: { bytes: File.size(path) }) { Digest::SHA256.file(path).hexdigest }
               end
      {
        passed: true,
        engine: engine.to_s,
        profile: profile,
        bytes: File.size(path),
        sha256: sha256,
        comparison: comparison,
        decoded: decoded
      }
    end

    def read(path, engine:)
      case engine.to_s.downcase
      when 'e1' then read_e1(path)
      when 'e2' then read_e2(path)
      when 'e3' then read_e3(path)
      else raise ValidationError, "Unsupported Evolution engine #{engine}"
      end
    end

    def read_e1(path)
      bytes = File.binread(path)
      raise ValidationError, 'E1 must be plain JSON' unless bytes.start_with?('{')
      payload = JSON.parse(bytes)
      raise ValidationError, 'Unsupported E1 schema version' unless payload['schema_version'] == '2.2'
      raise ValidationError, 'Wrong E1 format identifier' unless payload['format'] == 'sibambo-evolution-e1'
      evolution = validate_evolution!(payload.fetch('evolution'), 'e1', payload.fetch('profile'))
      assets = decode_json_assets(payload['assets'])
      { engine: 'e1', profile: evolution.fetch('profile'), tree: payload, assets: assets }
    rescue JSON::ParserError => error
      raise ValidationError, "Invalid E1 JSON: #{error.message}"
    end
    private_class_method :read_e1

    def read_e2(path)
      payload = File.open(path, 'rb') do |file|
        raise ValidationError, 'E2 must be gzip JSON' unless file.read(2) == "\x1f\x8b".b
        file.rewind
        gzip = Zlib::GzipReader.new(file)
        begin
          gzip.read
        ensure
          gzip.close
        end
      end
      graph = JSON.parse(payload)
      format = graph.fetch('format')
      raise ValidationError, 'Wrong E2 format identifier' unless format['name'] == 'BOM Engine Canonical'
      raise ValidationError, 'Unsupported E2 version' unless format['version'] == '3.1.0'
      evolution = validate_evolution!(graph.fetch('evolution'), 'e2', graph.dig('evolution', 'profile'))
      assets = decode_json_assets(graph.delete('assets'))
      document = { 'contract' => EvolutionDocument::CONTRACT, 'engine' => 'e2', 'profile' => evolution.fetch('profile'), 'graph' => graph, 'assets' => assets }
      EvolutionDocument.validate!(document)
      { engine: 'e2', profile: evolution.fetch('profile'), document: document, graph: graph, assets: assets }
    rescue JSON::ParserError, Zlib::GzipFile::Error, EOFError => error
      raise ValidationError, "Invalid E2 gzip JSON: #{error.message}"
    end
    private_class_method :read_e2

    def read_e3(path)
      entries = read_zip_entries_file(path)
      manifest_bytes = entries.fetch('manifest.json') { raise ValidationError, 'E3 manifest.json missing' }
      buffers = entries.fetch('buffers.bin') { raise ValidationError, 'E3 buffers.bin missing' }
      manifest = JSON.parse(manifest_bytes)
      format = manifest.fetch('format')
      raise ValidationError, 'Wrong E3 format identifier' unless format['identifier'] == 'bom_engine_clean_package'
      raise ValidationError, 'Unsupported E3 version' unless format['version'] == '1.1.0'
      evolution = validate_evolution!(manifest.fetch('evolution'), 'e3', manifest.dig('evolution', 'profile'))
      expected_length = Integer(manifest.dig('buffers', 'byte_length'))
      raise ValidationError, 'E3 buffer length mismatch' unless buffers.bytesize == expected_length
      assets = Array(manifest['assets']).map do |asset|
        raw = entries.fetch(asset.fetch('path')) { raise ValidationError, "Missing E3 asset #{asset['path']}" }
        validate_asset_bytes!(asset, raw)
        asset.merge('bytes' => raw)
      end
      graph = decode_e3_graph(manifest, buffers)
      document = { 'contract' => EvolutionDocument::CONTRACT, 'engine' => 'e3', 'profile' => evolution.fetch('profile'), 'graph' => graph, 'assets' => assets }
      EvolutionDocument.validate!(document)
      { engine: 'e3', profile: evolution.fetch('profile'), document: document, graph: graph, assets: assets, manifest: manifest }
    rescue JSON::ParserError => error
      raise ValidationError, "Invalid E3 manifest: #{error.message}"
    end
    private_class_method :read_e3

    def compare!(source_document, decoded)
      EvolutionDocument.validate!(source_document)
      return compare_e1!(source_document, decoded) if decoded.fetch(:engine) == 'e1'

      compare_compact!(source_document, decoded)
    end

    def compare_e1!(source_document, decoded)
      source_tree = EvolutionTreeWriter.build(source_document)
      target_tree = decoded.fetch(:tree)
      source_rows = face_rows(source_tree)
      target_rows = face_rows(target_tree)
      raise ValidationError, 'Occurrence face identity set changed during readback' unless source_rows.keys == target_rows.keys
      source_rows.each do |identity, row|
        unless canonical_json(row) == canonical_json(target_rows.fetch(identity))
          raise ValidationError, "Occurrence fidelity mismatch for #{identity}"
        end
      end
      source_edges = edge_rows(source_tree)
      target_edges = edge_rows(target_tree)
      raise ValidationError, 'Occurrence edge identity set changed during readback' unless source_edges.keys == target_edges.keys
      source_edges.each do |identity, row|
        raise ValidationError, "Occurrence edge fidelity mismatch for #{identity}" unless canonical_json(row) == canonical_json(target_edges.fetch(identity))
      end
      compare_fallbacks!(source_tree, target_tree)
      compare_json!(source_tree['scenes'], target_tree['scenes'], 'scenes')
      compare_json!(source_tree['clip_planes'], target_tree['clip_planes'], 'clip planes')
      compare_assets!(source_document.fetch('assets'), decoded.fetch(:assets))
      {
        mode: 'world-expanded', occurrences: source_rows.length, edges: source_edges.length,
        scenes: Array(source_tree['scenes']).length, clip_planes: Array(source_tree['clip_planes']).length,
        assets: Array(source_document['assets']).length
      }
    end
    private_class_method :compare_e1!

    def compare_compact!(source_document, decoded)
      target_document = decoded.fetch(:document)
      EvolutionDocument.validate!(target_document)
      source_graph = source_document.fetch('graph')
      target_graph = target_document.fetch('graph')

      compare_digest!(source_graph.fetch('evolution'), target_graph.fetch('evolution'), 'evolution metadata')
      %w[units coordinate_system source metadata tags materials definitions scenes clip_planes scene_fidelity_manifest].each do |key|
        compare_digest!(compact_graph_value(source_graph, key), compact_graph_value(target_graph, key), key.tr('_', ' '))
      end
      compare_definition_local_geometry!(source_graph, target_graph)
      compare_occurrence_bindings!(source_graph, target_graph)
      compare_assets!(source_document.fetch('assets'), decoded.fetch(:assets))

      source_counts = occurrence_geometry_counts(source_graph)
      target_counts = occurrence_geometry_counts(target_graph)
      raise ValidationError, 'Occurrence geometry count changed during compact readback' unless source_counts == target_counts
      {
        mode: 'compact-definition-occurrence', occurrences: source_counts.fetch(:faces), edges: source_counts.fetch(:edges),
        scenes: Array(source_graph['scenes']).length, clip_planes: Array(source_graph['clip_planes']).length,
        assets: Array(source_document['assets']).length
      }
    end
    private_class_method :compare_compact!

    def compact_graph_value(graph, key)
      case key
      when 'units', 'coordinate_system', 'source', 'metadata', 'scene_fidelity_manifest'
        graph[key] || {}
      when 'tags', 'materials', 'definitions', 'scenes', 'clip_planes'
        graph[key] || []
      else
        graph[key]
      end
    end
    private_class_method :compact_graph_value

    def compare_definition_local_geometry!(source_graph, target_graph)
      source_meshes = definition_local_geometry_digests(source_graph)
      target_meshes = definition_local_geometry_digests(target_graph)
      raise ValidationError, 'Definition-local mesh identity set changed during readback' unless source_meshes.keys == target_meshes.keys
      source_meshes.each do |id, digest|
        unless digest == target_meshes.fetch(id)
          raise ValidationError, "Definition-local geometry/material/UV/topology mismatch for #{id}"
        end
      end
      true
    end
    private_class_method :compare_definition_local_geometry!

    def definition_local_geometry_digests(graph)
      Array(graph['meshes']).each_with_object({}) do |mesh, digests|
        id = mesh.fetch('id')
        raise ValidationError, "Duplicate mesh identity #{id}" if digests.key?(id)
        digests[id] = canonical_digest(normalized_mesh_row(mesh))
      end.sort.to_h
    end
    private_class_method :definition_local_geometry_digests

    def normalized_mesh_row(mesh)
      faces = Array(mesh['faces']).map do |face|
        normalized = {
          'id' => face['id'],
          'source_identity' => EvolutionDocument.deep_copy(face['source_identity'] || {}),
          'outer' => Array(face['outer']).map { |value| Integer(value) },
          'holes' => Array(face['holes']).map { |loop| Array(loop).map { |value| Integer(value) } },
          'triangles' => Array(face['triangles']).map { |value| Integer(value) },
          'normal' => Array(face['normal'] || [0.0, 0.0, 1.0]).map { |value| Float(value) },
          'area_m2' => Float(face['area_m2'] || 0.0),
          'front_material_id' => face['front_material_id'],
          'back_material_id' => face['back_material_id'],
          'front_appearance_required' => face['front_appearance_required'] != false,
          'back_appearance_required' => face['back_appearance_required'] == true,
          'tag_id' => face['tag_id'],
          'hidden' => face['hidden'] == true,
          'surface_hint' => face['surface_hint'],
          'semantic' => EvolutionDocument.deep_copy(face['semantic'] || {})
        }
        normalized['uv'] = normalized_uv(face['uv']) if face.key?('uv')
        normalized
      end
      edges = Array(mesh['edges']).map do |edge|
        normalized = EvolutionDocument.deep_copy(edge)
        normalized['vertices'] = Array(edge['vertices']).map { |value| Integer(value) }
        normalized
      end
      {
        'id' => mesh.fetch('id'),
        'definition_id' => mesh['definition_id'],
        'positions_m' => Array(mesh.fetch('positions_m')).map { |value| Float(value) },
        'faces' => faces,
        'edges' => edges
      }
    rescue ArgumentError, TypeError => error
      raise ValidationError, "Invalid definition-local mesh #{mesh['id']}: #{error.message}"
    end
    private_class_method :normalized_mesh_row

    def normalized_uv(uv)
      value = uv || {}
      result = {}
      %w[front_outer back_outer].each do |key|
        next unless value[key].is_a?(Array)
        result[key] = Array(value[key]).map { |pair| [Float(pair.fetch(0)), Float(pair.fetch(1))] }
      end
      %w[front_holes back_holes].each do |key|
        next unless value[key].is_a?(Array)
        result[key] = Array(value[key]).map do |loop|
          Array(loop).map { |pair| [Float(pair.fetch(0)), Float(pair.fetch(1))] }
        end
      end
      result
    end
    private_class_method :normalized_uv

    def compare_occurrence_bindings!(source_graph, target_graph)
      source_rows = occurrence_binding_rows(source_graph)
      target_rows = occurrence_binding_rows(target_graph)
      raise ValidationError, 'Occurrence identity set changed during readback' unless source_rows.keys == target_rows.keys
      source_rows.each do |id, digest|
        raise ValidationError, "Occurrence binding mismatch for #{id}" unless digest == target_rows.fetch(id)
      end
      true
    end
    private_class_method :compare_occurrence_bindings!

    def occurrence_binding_rows(graph)
      transforms = Array(graph['transforms'])
      Array(graph['nodes']).each_with_object({}) do |node, rows|
        id = node.fetch('id')
        raise ValidationError, "Duplicate occurrence identity #{id}" if rows.key?(id)
        transform_id = Integer(node['transform_id'] || 0)
        matrix = transforms.fetch(transform_id) { raise ValidationError, "Missing transform #{transform_id} for #{id}" }
        row = node.reject { |key, _| key == 'transform_id' }.merge('world_binding_transform' => matrix)
        rows[id] = canonical_digest(row)
      end.sort.to_h
    rescue IndexError, ArgumentError => error
      raise ValidationError, "Invalid occurrence binding: #{error.message}"
    end
    private_class_method :occurrence_binding_rows

    def occurrence_geometry_counts(graph)
      definitions = Array(graph['definitions']).each_with_object({}) { |definition, map| map[definition.fetch('id')] = definition }
      meshes = Array(graph['meshes']).each_with_object({}) { |mesh, map| map[mesh.fetch('id')] = mesh }
      nodes = Array(graph['nodes']).each_with_object({}) { |node, map| map[node.fetch('id')] = node }
      root = Array(graph['nodes']).find { |node| node['kind'] == 'root' }
      raise ValidationError, 'Compact graph requires exactly one root node' unless root
      count_definition_occurrences(root.fetch('definition_id'), definitions, meshes, nodes, [])
    end
    private_class_method :occurrence_geometry_counts

    def count_definition_occurrences(definition_id, definitions, meshes, nodes, ancestry)
      raise ValidationError, "Recursive definition cycle: #{(ancestry + [definition_id]).join(' -> ')}" if ancestry.include?(definition_id)
      definition = definitions.fetch(definition_id) { raise ValidationError, "Missing definition #{definition_id}" }
      next_ancestry = ancestry + [definition_id]
      faces = 0
      edges = 0
      if definition['mesh_id']
        mesh = meshes.fetch(definition['mesh_id']) { raise ValidationError, "Missing mesh #{definition['mesh_id']}" }
        faces += Array(mesh['faces']).length
        edges += Array(mesh['edges']).length
      end
      Array(definition['node_ids']).each do |node_id|
        node = nodes.fetch(node_id) { raise ValidationError, "Missing node #{node_id}" }
        next unless node['definition_id']
        child = count_definition_occurrences(node['definition_id'], definitions, meshes, nodes, next_ancestry)
        faces += child.fetch(:faces)
        edges += child.fetch(:edges)
      end
      { faces: faces, edges: edges }
    end
    private_class_method :count_definition_occurrences

    def validate_evolution!(metadata, engine, fallback_profile)
      raise ValidationError, 'Evolution metadata must be an object' unless metadata.is_a?(Hash)
      raise ValidationError, 'Wrong Evolution contract' unless metadata['contract'] == EvolutionDocument::CONTRACT
      raise ValidationError, "Evolution engine mismatch: #{metadata['engine']}" unless metadata['engine'] == engine
      profile = (metadata['profile'] || fallback_profile).to_s
      raise ValidationError, "Unsupported Evolution profile #{profile}" unless %w[visual research exact].include?(profile)
      raise ValidationError, 'Invalid source_tree_sha256' unless metadata['source_tree_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/)
      raise ValidationError, 'Invalid historical_baseline_sha' unless metadata['historical_baseline_sha'].to_s.match?(/\A[0-9a-f]{40}\z/)
      metadata.merge('profile' => profile)
    end
    private_class_method :validate_evolution!

    def decode_json_assets(rows)
      Array(rows).map do |asset|
        raw = Base64.strict_decode64(asset.fetch('data_base64'))
        clean = asset.reject { |key, _| key == 'data_base64' }
        validate_asset_bytes!(clean, raw)
        clean.merge('bytes' => raw)
      rescue ArgumentError => error
        raise ValidationError, "Invalid base64 asset #{asset['id']}: #{error.message}"
      end
    end
    private_class_method :decode_json_assets

    def validate_asset_bytes!(asset, raw)
      raise ValidationError, "Asset #{asset['id']} byte length mismatch" unless Integer(asset.fetch('byte_length')) == raw.bytesize
      raise ValidationError, "Asset #{asset['id']} hash mismatch" unless asset.fetch('sha256') == Digest::SHA256.hexdigest(raw)
      true
    end
    private_class_method :validate_asset_bytes!

    def face_rows(tree)
      rows = {}
      walk = lambda do |entities|
        Array(entities).each do |entity|
          if entity['type'] == 'Face'
            identity = [entity['instance_path'], entity['source_face_id']].join('|')
            raise ValidationError, "Duplicate occurrence identity #{identity}" if rows.key?(identity)
            rows[identity] = entity.reject { |key, _| key == 'id' }
          else
            walk.call(entity['children'])
          end
        end
      end
      walk.call(tree['entities'])
      rows.sort.to_h
    end
    private_class_method :face_rows

    def edge_rows(tree)
      rows = {}
      walk = lambda do |entities|
        Array(entities).each do |entity|
          if entity['type'] == 'Edge'
            identity = [entity['instance_path'], entity['source_edge_id']].join('|')
            raise ValidationError, "Duplicate edge occurrence identity #{identity}" if rows.key?(identity)
            rows[identity] = entity.reject { |key, _| key == 'id' }
          elsif entity['children']
            walk.call(entity['children'])
          end
        end
      end
      walk.call(tree['entities'])
      rows.sort.to_h
    end
    private_class_method :edge_rows

    def compare_fallbacks!(source_tree, target_tree)
      collect = lambda do |tree|
        rows = []
        walk = lambda do |entities|
          Array(entities).each do |entity|
            if %w[Image Text].include?(entity['type'])
              rows << entity.reject { |key, _| key == 'id' }
            elsif entity['children']
              walk.call(entity['children'])
            end
          end
        end
        walk.call(tree['entities'])
        rows.sort_by { |row| [row['instance_path'].to_s, row['source_node_id'].to_s] }
      end
      raise ValidationError, 'Fallback image/text nodes changed during readback' unless canonical_json(collect.call(source_tree)) == canonical_json(collect.call(target_tree))
    end
    private_class_method :compare_fallbacks!

    def canonical_json(value)
      case value
      when Hash
        '{' + value.keys.map(&:to_s).sort.map do |key|
          child = value.key?(key) ? value[key] : value[key.to_sym]
          "#{JSON.generate(key)}:#{canonical_json(child)}"
        end.join(',') + '}'
      when Array
        '[' + value.map { |child| canonical_json(child) }.join(',') + ']'
      else
        JSON.generate(value)
      end
    end
    private_class_method :canonical_json

    def compare_json!(left, right, label)
      raise ValidationError, "#{label} changed during readback" unless canonical_json(left || []) == canonical_json(right || [])
    end
    private_class_method :compare_json!

    def compare_assets!(left, right)
      normalize = lambda do |items|
        Array(items).map { |asset| [asset.fetch('id'), asset.fetch('sha256'), asset.fetch('byte_length')] }.sort
      end
      raise ValidationError, 'Asset table changed during readback' unless normalize.call(left) == normalize.call(right)
    end
    private_class_method :compare_assets!

    def compare_digest!(left, right, label)
      raise ValidationError, "#{label} changed during readback" unless canonical_digest(left) == canonical_digest(right)
    end
    private_class_method :compare_digest!

    def canonical_digest(value)
      digest = Digest::SHA256.new
      append_canonical_digest(digest, value)
      digest.hexdigest
    end
    private_class_method :canonical_digest

    def append_canonical_digest(digest, value)
      case value
      when Hash
        digest.update('{')
        value.keys.map(&:to_s).sort.each_with_index do |key, index|
          digest.update(',') unless index.zero?
          digest.update(JSON.generate(key))
          digest.update(':')
          child = value.key?(key) ? value[key] : value[key.to_sym]
          append_canonical_digest(digest, child)
        end
        digest.update('}')
      when Array
        digest.update('[')
        value.each_with_index do |child, index|
          digest.update(',') unless index.zero?
          append_canonical_digest(digest, child)
        end
        digest.update(']')
      else
        digest.update(JSON.generate(value))
      end
    end
    private_class_method :append_canonical_digest

    def normalize_sha256(value)
      text = value.to_s.downcase
      raise ValidationError, 'Invalid artifact SHA-256' unless text.match?(/\A[0-9a-f]{64}\z/)
      text
    end
    private_class_method :normalize_sha256

    def read_zip_entries_file(path)
      File.open(path, 'rb') { |file| read_zip_entries_io(file) }
    end
    private_class_method :read_zip_entries_file

    def read_zip_entries(bytes)
      read_zip_entries_io(StringIO.new(bytes))
    end
    private_class_method :read_zip_entries

    def read_zip_entries_io(io)
      entries = {}
      entry_metadata = {}
      cursor = 0
      loop do
        signature_bytes = io.read(4)
        break unless signature_bytes
        raise ValidationError, 'Truncated E3 ZIP signature' unless signature_bytes.bytesize == 4
        signature = signature_bytes.unpack1('V')
        if signature == 0x02014b50
          validate_zip_central_directory!(io, signature_bytes, entries, entry_metadata, cursor)
          return entries
        elsif signature == 0x06054b50
          raise ValidationError, 'E3 ZIP central directory missing'
        end
        raise ValidationError, "Invalid E3 ZIP local header at byte #{cursor}" unless signature == 0x04034b50
        local_offset = cursor
        remainder = io.read(26)
        raise ValidationError, 'Truncated E3 ZIP header' unless remainder && remainder.bytesize == 26
        header = signature_bytes + remainder
        fields = header.unpack('VvvvvvVVVvv')
        method = fields[3]
        crc = fields[6]
        compressed_size = fields[7]
        raw_size = fields[8]
        name_length = fields[9]
        extra_length = fields[10]
        name = io.read(name_length)
        raise ValidationError, 'Truncated E3 ZIP entry name' unless name && name.bytesize == name_length
        extra = io.read(extra_length)
        raise ValidationError, "Truncated E3 ZIP extra field for #{name}" unless extra && extra.bytesize == extra_length
        encoded = io.read(compressed_size)
        raise ValidationError, "Truncated E3 ZIP entry #{name}" unless encoded && encoded.bytesize == compressed_size
        raw = case method
              when 0 then encoded
              when 8 then inflate_raw(encoded)
              else raise ValidationError, "Unsupported E3 ZIP compression method #{method}"
              end
        raise ValidationError, "E3 ZIP size mismatch for #{name}" unless raw.bytesize == raw_size
        raise ValidationError, "E3 ZIP CRC mismatch for #{name}" unless Zlib.crc32(raw) == crc
        key = name.force_encoding('UTF-8')
        raise ValidationError, "Duplicate E3 ZIP entry #{key}" if entries.key?(key)
        entries[key] = raw
        entry_metadata[key] = {
          raw_size: raw_size,
          compressed_size: compressed_size,
          crc: crc,
          method: method,
          local_offset: local_offset
        }
        cursor += 30 + name_length + extra_length + compressed_size
      end
      raise ValidationError, 'E3 ZIP contained no local entries' if entries.empty?
      raise ValidationError, 'Truncated E3 ZIP central directory'
    end
    private_class_method :read_zip_entries_io

    def validate_zip_central_directory!(io, first_signature, entries, entry_metadata, central_offset)
      signature_bytes = first_signature
      central_count = 0
      central_bytes = 0
      loop do
        signature = signature_bytes.unpack1('V')
        if signature == 0x02014b50
          remainder = io.read(42)
          raise ValidationError, 'Truncated E3 ZIP central header' unless remainder && remainder.bytesize == 42
          header = signature_bytes + remainder
          fields = header.unpack('VvvvvvvVVVvvvvvVV')
          method = fields[4]
          crc = fields[7]
          compressed_size = fields[8]
          raw_size = fields[9]
          name_length = fields[10]
          extra_length = fields[11]
          comment_length = fields[12]
          local_offset = fields[16]
          name = io.read(name_length)
          raise ValidationError, 'Truncated E3 ZIP central entry name' unless name && name.bytesize == name_length
          extra = io.read(extra_length)
          raise ValidationError, "Truncated E3 ZIP central extra field for #{name}" unless extra && extra.bytesize == extra_length
          comment = io.read(comment_length)
          raise ValidationError, "Truncated E3 ZIP central comment for #{name}" unless comment && comment.bytesize == comment_length
          key = name.force_encoding('UTF-8')
          metadata = entry_metadata.fetch(key) { raise ValidationError, "E3 ZIP central entry #{key} has no local entry" }
          unless metadata == { raw_size: raw_size, compressed_size: compressed_size, crc: crc, method: method, local_offset: local_offset }
            raise ValidationError, "E3 ZIP central metadata mismatch for #{key}"
          end
          central_count += 1
          central_bytes += 46 + name_length + extra_length + comment_length
          signature_bytes = io.read(4)
          raise ValidationError, 'Truncated E3 ZIP after central entry' unless signature_bytes && signature_bytes.bytesize == 4
          next
        end

        raise ValidationError, 'E3 ZIP end-of-central-directory missing' unless signature == 0x06054b50
        remainder = io.read(18)
        raise ValidationError, 'Truncated E3 ZIP end-of-central-directory' unless remainder && remainder.bytesize == 18
        footer = signature_bytes + remainder
        fields = footer.unpack('VvvvvVVv')
        disk_number = fields[1]
        central_disk = fields[2]
        disk_entries = fields[3]
        total_entries = fields[4]
        declared_central_bytes = fields[5]
        declared_central_offset = fields[6]
        comment_length = fields[7]
        raise ValidationError, 'Multi-disk E3 ZIP is unsupported' unless disk_number.zero? && central_disk.zero?
        raise ValidationError, 'E3 ZIP central entry count mismatch' unless disk_entries == central_count && total_entries == central_count && central_count == entries.length
        raise ValidationError, 'E3 ZIP central byte length mismatch' unless declared_central_bytes == central_bytes
        raise ValidationError, 'E3 ZIP central offset mismatch' unless declared_central_offset == central_offset
        comment = io.read(comment_length)
        raise ValidationError, 'Truncated E3 ZIP comment' unless comment && comment.bytesize == comment_length
        raise ValidationError, 'Unexpected trailing bytes after E3 ZIP' if io.read(1)
        return true
      end
    end
    private_class_method :validate_zip_central_directory!

    def inflate_raw(bytes)
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      inflater.inflate(bytes) + inflater.finish
    ensure
      inflater&.close
    end
    private_class_method :inflate_raw

    def decode_e3_graph(manifest, buffers)
      materials = EvolutionDocument.deep_copy(manifest['materials'] || [])
      asset_by_id = Array(manifest['assets']).each_with_object({}) { |asset, map| map[asset['id']] = asset }
      materials.each do |material|
        texture = material['texture']
        next unless texture && texture['asset']
        asset = asset_by_id.fetch(texture['asset']) { raise ValidationError, "Unknown E3 material asset #{texture['asset']}" }
        material['texture'] = texture.reject { |key, _| key == 'asset' }.merge('asset_id' => asset['id'], 'filename' => File.basename(asset['path']))
      end

      meshes = Array(manifest['meshes']).map do |mesh|
        binary = mesh.fetch('binary')
        positions = section_values(manifest, buffers, binary.fetch('positions'))
        outer_indices = section_values(manifest, buffers, binary.fetch('outer_indices')).map(&:to_i)
        outer_offsets = section_values(manifest, buffers, binary.fetch('outer_offsets')).map(&:to_i)
        hole_indices = section_values(manifest, buffers, binary.fetch('hole_indices')).map(&:to_i)
        hole_offsets = section_values(manifest, buffers, binary.fetch('hole_offsets')).map(&:to_i)
        face_hole_offsets = section_values(manifest, buffers, binary.fetch('face_hole_offsets')).map(&:to_i)
        triangles = section_values(manifest, buffers, binary.fetch('triangles')).map(&:to_i)
        triangle_offsets = section_values(manifest, buffers, binary.fetch('triangle_offsets')).map(&:to_i)
        normals = section_values(manifest, buffers, binary.fetch('normals'))
        areas = section_values(manifest, buffers, binary.fetch('areas'))
        front_materials = section_values(manifest, buffers, binary.fetch('front_material_indices')).map(&:to_i)
        back_materials = section_values(manifest, buffers, binary.fetch('back_material_indices')).map(&:to_i)
        front_uv_values = section_values(manifest, buffers, binary.fetch('front_uv_values'))
        front_uv_offsets = section_values(manifest, buffers, binary.fetch('front_uv_offsets')).map(&:to_i)
        back_uv_values = section_values(manifest, buffers, binary.fetch('back_uv_values'))
        back_uv_offsets = section_values(manifest, buffers, binary.fetch('back_uv_offsets')).map(&:to_i)
        edge_vertices = section_values(manifest, buffers, binary.fetch('edge_vertices')).map(&:to_i)
        face_metadata = Array(mesh['face_metadata'])
        faces = face_metadata.each_with_index.map do |metadata, face_index|
          hole_begin = face_hole_offsets.fetch(face_index)
          hole_end = face_hole_offsets.fetch(face_index + 1)
          holes = (hole_begin...hole_end).map do |hole_index|
            hole_indices.slice(hole_offsets.fetch(hole_index)...hole_offsets.fetch(hole_index + 1))
          end
          front_uv = decode_face_uv(front_uv_values, front_uv_offsets.fetch(face_index + 1), metadata['front_uv_loop_lengths'])
          back_uv = decode_face_uv(back_uv_values, back_uv_offsets.fetch(face_index + 1), metadata['back_uv_loop_lengths'])
          clean_metadata = EvolutionDocument.deep_copy(metadata).reject do |key, _|
            %w[front_uv_loop_lengths back_uv_loop_lengths].include?(key)
          end
          face = clean_metadata.merge(
            'outer' => outer_indices.slice(outer_offsets.fetch(face_index)...outer_offsets.fetch(face_index + 1)),
            'holes' => holes,
            'triangles' => triangles.slice(triangle_offsets.fetch(face_index)...triangle_offsets.fetch(face_index + 1)),
            'normal' => normals.slice(face_index * 3, 3),
            'area_m2' => areas.fetch(face_index),
            'front_material_id' => material_id(materials, front_materials.fetch(face_index)),
            'back_material_id' => material_id(materials, back_materials.fetch(face_index))
          )
          uv = {}
          unless Array(metadata['front_uv_loop_lengths']).empty?
            uv['front_outer'] = front_uv[0]
            uv['front_holes'] = front_uv.drop(1)
          end
          unless Array(metadata['back_uv_loop_lengths']).empty?
            uv['back_outer'] = back_uv[0]
            uv['back_holes'] = back_uv.drop(1)
          end
          face['uv'] = uv unless uv.empty?
          face
        end
        edges = Array(mesh['edge_metadata']).each_with_index.map do |metadata, edge_index|
          EvolutionDocument.deep_copy(metadata).merge('vertices' => edge_vertices.slice(edge_index * 2, 2))
        end
        {
          'id' => mesh.fetch('id'),
          'definition_id' => mesh['definition_id'],
          'positions_m' => positions,
          'faces' => faces,
          'edges' => edges
        }
      end

      definitions = Array(manifest['definitions']).map do |definition|
        EvolutionDocument.deep_copy(definition).reject { |key, _| key == 'mesh_index' }
      end
      instances = manifest.fetch('instances_v1_1')
      instance_metadata = Array(instances['metadata'])
      transforms = section_values(manifest, buffers, instances.fetch('transforms')).each_slice(16).map(&:dup)
      definition_indices = section_values(manifest, buffers, instances.fetch('definition_indices')).map(&:to_i)
      material_indices = section_values(manifest, buffers, instances.fetch('material_indices')).map(&:to_i)
      nodes = instance_metadata.each_with_index.map do |metadata, index|
        definition_index = definition_indices.fetch(index)
        definition_id = definition_index == UINT32_NONE ? nil : definitions.fetch(definition_index).fetch('id')
        EvolutionDocument.deep_copy(metadata).merge(
          'transform_id' => index,
          'definition_id' => definition_id,
          'material_override_id' => material_id(materials, material_indices.fetch(index))
        )
      end
      {
        'format' => { 'name' => 'BOM Engine Canonical', 'version' => '3.1.0' },
        'evolution' => EvolutionDocument.deep_copy(manifest.fetch('evolution')),
        'units' => EvolutionDocument.deep_copy(manifest['units'] || {}),
        'coordinate_system' => EvolutionDocument.deep_copy(manifest['coordinate_system'] || {}),
        'source' => EvolutionDocument.deep_copy(manifest['source'] || {}),
        'metadata' => EvolutionDocument.deep_copy(manifest['metadata'] || {}),
        'tags' => EvolutionDocument.deep_copy(manifest['tags'] || []),
        'materials' => materials,
        'transforms' => transforms,
        'meshes' => meshes,
        'definitions' => definitions,
        'nodes' => nodes,
        'scenes' => EvolutionDocument.deep_copy(manifest['scenes'] || []),
        'clip_planes' => EvolutionDocument.deep_copy(manifest['clip_planes'] || []),
        'scene_fidelity_manifest' => EvolutionDocument.deep_copy(manifest['scene_fidelity_manifest'] || {})
      }
    end
    private_class_method :decode_e3_graph

    def section_values(manifest, buffers, reference)
      section_index = Integer(reference.fetch('section'))
      fields = manifest.dig('buffers', 'section_descriptor_fields')
      raise ValidationError, 'Unsupported E3 section descriptor fields' unless fields == %w[byte_offset byte_length count component_count component_type]
      descriptor = Array(manifest.dig('buffers', 'sections')).fetch(section_index)
      offset, byte_length, count, components, type = descriptor
      offset = Integer(offset); byte_length = Integer(byte_length); count = Integer(count); components = Integer(components)
      raise ValidationError, "E3 section #{section_index} is out of bounds" if offset.negative? || byte_length.negative? || offset + byte_length > buffers.bytesize
      directive, width = case type
                         when 'float64' then ['E*', 8]
                         when 'uint32' then ['L<*', 4]
                         when 'int32' then ['l<*', 4]
                         else raise ValidationError, "Unsupported E3 component type #{type}"
                         end
      expected = count * components * width
      raise ValidationError, "E3 section #{section_index} byte length mismatch" unless expected == byte_length
      values = buffers.byteslice(offset, byte_length).unpack(directive)
      raise ValidationError, "E3 section #{section_index} decoded length mismatch" unless values.length == count * components
      values
    rescue IndexError, KeyError, ArgumentError => error
      raise ValidationError, "Invalid E3 section reference: #{error.message}"
    end
    private_class_method :section_values

    def decode_face_uv(values, offset, loop_lengths)
      lengths = Array(loop_lengths).map(&:to_i)
      return [] if offset == UINT32_NONE || lengths.empty?
      count = lengths.sum
      flat = values.slice(offset * 2, count * 2)
      raise ValidationError, 'E3 UV section shorter than loop metadata' unless flat && flat.length == count * 2
      pairs = flat.each_slice(2).map(&:dup)
      cursor = 0
      lengths.map do |length|
        loop = pairs.slice(cursor, length)
        cursor += length
        loop
      end
    end
    private_class_method :decode_face_uv

    def material_id(materials, index)
      return nil if index == UINT32_NONE
      materials.fetch(index).fetch('id')
    rescue IndexError
      raise ValidationError, "E3 material index #{index} out of range"
    end
    private_class_method :material_id
  end
end
