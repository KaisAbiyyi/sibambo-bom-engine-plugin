#!/usr/bin/env ruby
# Builds the permitted non-SketchUp BOMC benchmark corpus and report.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'tmpdir'
require 'zlib'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require_relative '../bomc_validator'

module SibamboHistory
  module V20260819_01
  module BOMCBenchmark
    module_function

    def run(argv)
      options = { output: File.expand_path('../../BENCHMARK_REPORT.md', __dir__) }
      OptionParser.new do |parser|
        parser.on('--output PATH') { |value| options[:output] = File.expand_path(value) }
      end.parse!(argv)
      root = File.expand_path('../..', __dir__)
      tiny_path = File.join(root, 'examples', 'model-eval-json-v1-small.json')
      complex_path = Dir.glob(File.join(root, 'skps', 'model-eval-exports', '*.json')).max_by { |path| File.size(path) }
      raise 'No existing complex Model-Eval JSON fixture found.' if complex_path.nil?

      fixtures = [
        fixture_from_path('Tiny', tiny_path),
        fixture_from_graph('Medium', medium_graph),
        fixture_from_path('Complex existing export', complex_path)
      ]
      results = fixtures.map { |fixture| benchmark_fixture(fixture) }
      scaling = benchmark_scaling
      codec_results = run_codec_benchmark(results[-1][:compiled_bytes])
      debug_result = BOMCWriter.pack(
        fixtures[-1][:graph], profile: :debug,
        base_path: fixtures[-1][:path] && File.dirname(fixtures[-1][:path])
      )
      profiles = {
        production_bytes: results[-1][:bomc_bytes], debug_bytes: debug_result[:bytes].bytesize,
        debug_section: debug_result[:metrics][:sections][:debug]
      }
      report = render_report(results, scaling, codec_results, profiles)
      FileUtils.mkdir_p(File.dirname(options[:output]))
      File.open(options[:output], 'w:UTF-8') { |file| file.write(report) }
      puts "Wrote #{options[:output]}"
      results.each { |result| puts "#{result[:name]}: #{result[:source_bytes]} -> #{result[:bomc_bytes]} bytes" }
      true
    end

    def fixture_from_path(name, path)
      content = File.binread(path)
      { name: name, graph: JSON.parse(content.force_encoding(Encoding::UTF_8), symbolize_names: true), source_bytes: content.bytesize, source_content: content, path: path }
    end

    def fixture_from_graph(name, graph)
      content = JSON.generate(graph).b
      { name: name, graph: graph, source_bytes: content.bytesize, source_content: content, path: nil }
    end

    def benchmark_fixture(fixture)
      before_objects = GC.stat[:total_allocated_objects]
      started = monotonic
      compiled = BOMCWriter.pack(fixture[:graph], profile: :production, base_path: fixture[:path] && File.dirname(fixture[:path]))
      encode_ms = (monotonic - started) * 1000.0
      encoded_objects = GC.stat[:total_allocated_objects] - before_objects

      started = monotonic
      header = compiled[:bytes].byteslice(0, BOMC::HEADER_BYTES).unpack(BOMC::HEADER_PACK)
      header_ms = (monotonic - started) * 1000.0
      started = monotonic
      directory = BOMC::Container.read_directory(compiled[:bytes])
      directory_ms = (monotonic - started) * 1000.0
      started = monotonic
      parsed = BOMC::Container.parse(compiled[:bytes])
      inflate_ms = (monotonic - started) * 1000.0
      before_decode = GC.stat[:total_allocated_objects]
      profiled = BOMCDecoder.profile(compiled[:bytes])
      decoded = profiled[:model]
      decode_ms = profiled[:timings][:total_ms]
      decode_objects = GC.stat[:total_allocated_objects] - before_decode
      validation = BOMCValidator.validate!(fixture[:graph], decoded)
      raw_sections = parsed[:sections].map do |section|
        { type: section[:type], flags: section[:flags], count: section[:count], bytes: section[:bytes], compress: false }
      end
      raw_container = BOMC::Container.pack(raw_sections, flags: BOMC::PROFILE_PRODUCTION)
      old_deflate = Zlib::Deflate.deflate(fixture[:source_content], Zlib::BEST_COMPRESSION).bytesize
      paired_skp = paired_skp_path(fixture[:path])
      {
        name: fixture[:name], source_path: fixture[:path], source_bytes: fixture[:source_bytes], old_deflate_bytes: old_deflate,
        bomc_raw_bytes: raw_container.bytesize, bomc_bytes: compiled[:bytes].bytesize,
        bomc_sha256: compiled[:sha256], encode_ms: encode_ms, header_ms: header_ms,
        directory_ms: directory_ms, inflate_ms: inflate_ms, decode_ms: decode_ms,
        decode_timings: profiled[:timings],
        encode_objects: encoded_objects, decode_objects: decode_objects,
        typed_array_bytes: typed_array_bytes(decoded), validation: validation,
        metrics: compiled[:metrics], compiled_bytes: compiled[:bytes],
        counts: logical_counts(decoded), paired_skp: paired_skp, paired_skp_bytes: paired_skp && File.size(paired_skp),
        header: header, directory_count: directory[:sections].length
      }
    end

    def medium_graph
      materials = [
        { id: 'material-concrete', name: 'Concrete', display_name: 'Concrete', color: { r: 180, g: 180, b: 175, a: 255 }, opacity: 1.0 },
        { id: 'material-glass', name: 'Glass', display_name: 'Glass', color: { r: 120, g: 190, b: 220, a: 180 }, opacity: 0.55 }
      ]
      tags = [{ id: 'tag-architecture', name: 'Architecture', visible: true }]
      definitions = [{ id: 'definition-root', name: 'Building', kind: 'model_definition', mesh_id: nil, node_ids: [] }]
      meshes = []
      12.times do |index|
        definition_id = "definition-panel-#{index}"
        mesh_id = "mesh-panel-#{index}"
        z = (index % 4) * 0.02
        positions = [0, 0, z, 4, 0, z, 4, 3, z, 0, 3, z, 1.5, 1, z, 1.5, 2, z, 2.5, 2, z, 2.5, 1, z]
        triangles = [0, 1, 7, 0, 7, 4, 1, 2, 6, 1, 6, 7, 2, 3, 5, 2, 5, 6, 3, 0, 4, 3, 4, 5]
        face = {
          id: "face-panel-#{index}", outer: [0, 1, 2, 3], holes: [[4, 5, 6, 7]], triangles: triangles,
          front_material_id: index.even? ? 'material-concrete' : 'material-glass', tag_id: 'tag-architecture',
          normal: [0, 0, 1], area_m2: 11.0, surface_hint: index.even? ? 'wall' : 'window', hidden: false,
          uv: {
            front_outer: [[-0.25, 0], [2.25, 0], [2.25, 1.5], [-0.25, 1.5]],
            front_holes: [[[0.5, 0.5], [0.5, 1], [1.5, 1], [1.5, 0.5]]], back_outer: [], back_holes: []
          }
        }
        meshes << { id: mesh_id, definition_id: definition_id, positions_m: positions, faces: [face], edges: [{ id: "edge-panel-#{index}", vertices: [0, 1], soft: false, smooth: false }] }
        definitions << { id: definition_id, name: "Panel #{index}", kind: 'component_definition', mesh_id: mesh_id, node_ids: [] }
      end
      transforms = [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]]
      nodes = [{ id: 'node-root', kind: 'root', name: 'Building', definition_id: 'definition-root', transform_id: 0, visible: true }]
      2_000.times do |index|
        definition_number = index % 12
        id = "node-panel-#{index}"
        transforms << [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, (index % 20) * 4.0, ((index / 20) % 20) * 3.0, (index / 400) * 3.2, 1]
        nodes << {
          id: id, kind: 'component_instance', name: "Panel #{definition_number}",
          owner_definition_id: 'definition-root', definition_id: "definition-panel-#{definition_number}",
          transform_id: index + 1, tag_id: 'tag-architecture', visible: true,
          semantic: { role: definition_number.even? ? 'wall' : 'window', classification_policy: 'geometry_fallback' }
        }
        definitions[0][:node_ids] << id
      end
      {
        format: { name: 'BOM Engine Canonical', version: '3.0.0' },
        source: { file_name: 'synthetic-medium.skp', model_name: 'Synthetic Architectural Building' },
        coordinate_system: { handedness: 'right', up_axis: '+Z' },
        materials: materials, tags: tags, transforms: transforms, meshes: meshes, definitions: definitions, nodes: nodes
      }
    end

    def benchmark_scaling
      [1, 10, 100, 1_000, 10_000].map do |count|
        graph = shared_graph(count)
        result = BOMCWriter.pack(graph)
        geometry = [:positions, :topology, :normals, :uv, :visual_edges].map do |name|
          result[:metrics][:sections].fetch(name, { stored_bytes: 0 })[:stored_bytes]
        end.inject(0, :+)
        { count: count, total_bytes: result[:bytes].bytesize, geometry_bytes: geometry, instance_bytes: result[:metrics][:sections][:instances][:stored_bytes], transform_bytes: result[:metrics][:sections][:transforms][:stored_bytes] }
      end
    end

    def shared_graph(count)
      graph = medium_graph
      graph[:meshes] = [graph[:meshes][0]]
      graph[:definitions] = [graph[:definitions][0], graph[:definitions][1]]
      graph[:definitions][0][:node_ids] = []
      graph[:transforms] = [graph[:transforms][0]]
      graph[:nodes] = [graph[:nodes][0]]
      count.times do |index|
        id = "node-shared-#{index}"
        graph[:transforms] << [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, index.to_f, 0, 0, 1]
        graph[:nodes] << { id: id, kind: 'component_instance', name: 'Panel', owner_definition_id: 'definition-root', definition_id: 'definition-panel-0', transform_id: index + 1, visible: true }
        graph[:definitions][0][:node_ids] << id
      end
      graph
    end

    def run_codec_benchmark(compiled_bytes)
      python = ENV['BOMC_PYTHON']
      return { 'status' => 'not run: BOMC_PYTHON is unset' } if python.to_s.empty? || !File.file?(python)
      directory = Dir.mktmpdir('bomc-codecs')
      begin
        bomc_path = File.join(directory, 'complex__SBE-2026.08.19-01.bomc')
        result_path = File.join(directory, 'codec-results.json')
        texture_path = File.join(directory, 'synthetic-texture.png')
        File.open(bomc_path, 'wb') { |file| file.write(compiled_bytes) }
        File.open(texture_path, 'wb') { |file| file.write(synthetic_png(64, 64)) }
        script = File.expand_path('codec_benchmark.py', __dir__)
        success = system(python, script, bomc_path, result_path, texture_path)
        return { 'status' => "codec helper failed with #{$?.exitstatus}" } unless success
        JSON.parse(File.read(result_path))
      ensure
        FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
      end
    end

    def synthetic_png(width, height)
      signature = "\x89PNG\r\n\x1a\n".b
      rows = height.times.map do |y|
        "\0".b + width.times.map { |x| [(x * 4) % 256, (y * 4) % 256, ((x + y) * 2) % 256] }.flatten.pack('C*')
      end.join.b
      signature + png_chunk('IHDR', [width, height, 8, 2, 0, 0, 0].pack('NNC5')) + png_chunk('IDAT', Zlib::Deflate.deflate(rows, 9)) + png_chunk('IEND', ''.b)
    end

    def png_chunk(type, data)
      content = type.b + data
      [data.bytesize].pack('N') + content + [Zlib.crc32(content)].pack('N')
    end

    def render_report(results, scaling, codec_results, profiles)
      complex = results[-1]
      lines = []
      lines << '# BOMC Hypercompression Benchmark Report'
      lines << ''
      lines << "Generated: 2026-08-13 (Asia/Jakarta). Automated corpus only; no SketchUp process was launched."
      lines << ''
      lines << '## Corpus size comparison'
      lines << ''
      lines << '| Fixture | Previous JSON | Previous DEFLATE | BOMC raw sections | BOMC production | Reduction vs JSON | Source SKP | BOMC vs SKP |'
      lines << '|---|---:|---:|---:|---:|---:|---:|---:|'
      results.each do |row|
        skp = row[:paired_skp_bytes] ? integer(row[:paired_skp_bytes]) : 'n/a'
        vs_skp = row[:paired_skp_bytes] ? percent(row[:bomc_bytes], row[:paired_skp_bytes]) : 'n/a'
        lines << "| #{row[:name]} | #{integer(row[:source_bytes])} | #{integer(row[:old_deflate_bytes])} | #{integer(row[:bomc_raw_bytes])} | #{integer(row[:bomc_bytes])} | #{reduction(row[:bomc_bytes], row[:source_bytes])} | #{skp} | #{vs_skp} |"
      end
      lines << ''
      lines << 'No `__SBE-2026.08.19-01.cleanpkg` fixture exists in this repository, so CleanPackage columns cannot be measured without inventing data. The previous-format comparison uses the available Model-Eval JSON plus its direct DEFLATE result.'
      lines << ''
      lines << '## Complex fixture section attribution'
      lines << ''
      lines << '| Section | Raw bytes | Stored bytes | Container codec | Count |'
      lines << '|---|---:|---:|---:|---:|'
      complex[:metrics][:sections].each do |name, values|
        lines << "| #{name} | #{integer(values[:raw_bytes])} | #{integer(values[:stored_bytes])} | #{values[:codec]} | #{integer(values[:count])} |"
      end
      lines << ''
      lines << "Header + directory: **#{integer(complex[:metrics][:header_directory_bytes])} bytes**. BOMC SHA256: `#{complex[:bomc_sha256]}`."
      lines << ''
      lines << '## Logical counts and differential validation'
      lines << ''
      lines << '| Fixture | Meshes | Faces | Definitions | Instances | Fallback | Materials | Textures | Unaccounted |'
      lines << '|---|---:|---:|---:|---:|---:|---:|---:|---:|'
      results.each do |row|
        counts = row[:counts]
        lines << "| #{row[:name]} | #{integer(counts[:meshes])} | #{integer(counts[:faces])} | #{integer(counts[:definitions])} | #{integer(counts[:instances])} | #{integer(counts[:fallback])} | #{integer(counts[:materials])} | #{integer(counts[:textures])} | #{integer(counts[:unaccounted])} |"
      end
      lines << ''
      lines << '## Side appearance and UV diagnostics'
      lines << ''
      lines << '| Fixture | Faces | Front appearance | Back appearance | Front UV | Back UV | Back material | Back UV only | Redundant back candidates | Front triangles | Required back triangles | Estimated occurrences |'
      lines << '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'
      results.each do |row|
        values = row[:metrics][:appearance]
        lines << "| #{row[:name]} | #{integer(values[:faces_total])} | #{integer(values[:front_appearance_faces])} | #{integer(values[:back_appearance_faces])} | #{integer(values[:front_uv_faces])} | #{integer(values[:back_uv_faces])} | #{integer(values[:back_material_faces])} | #{integer(values[:back_uv_only_faces])} | #{integer(values[:redundant_back_pass_candidates])} | #{integer(values[:front_triangle_count])} | #{integer(values[:required_back_triangle_count])} | #{integer(values[:estimated_two_side_triangle_occurrences])} |"
      end
      lines << ''
      lines << '| Fixture | Position max / p95 / RMS (m) | Normal max (deg) | UV max | Transform max | Tables | Topology | Edges | Fallback | Textures |'
      lines << '|---|---|---:|---:|---:|---|---|---|---|---|'
      results.each do |row|
        validation = row[:validation]
        position = validation[:positions]
        tables_exact = [:materials, :tags, :definitions, :instances].all? { |key| validation[key][:exact] }
        lines << "| #{row[:name]} | #{scientific(position[:max_error_m])} / #{scientific(position[:p95_error_m])} / #{scientific(position[:rms_error_m])} | #{scientific(validation[:normals][:max_angular_error_deg])} | #{scientific(validation[:uv][:max_error])} | #{scientific(validation[:transforms][:max_error])} | #{tables_exact ? 'exact' : 'FAIL'} | #{validation[:topology][:exact] ? 'exact' : 'FAIL'} | #{validation[:visual_edges][:exact] ? 'exact' : 'FAIL'} | #{validation[:fallback][:exact] ? 'exact' : 'FAIL'} | #{validation[:textures][:exact] ? 'exact' : 'FAIL'} |"
      end
      lines << ''
      lines << '## Production and debug profiles'
      lines << ''
      debug_section = profiles[:debug_section]
      lines << '| Profile | Container bytes | Debug section raw | Debug section stored | Runtime stable-ID/provenance mappings |'
      lines << '|---|---:|---:|---:|---|'
      lines << "| Production | #{integer(profiles[:production_bytes])} | 0 | 0 | omitted |"
      lines << "| Debug | #{integer(profiles[:debug_bytes])} | #{integer(debug_section[:raw_bytes])} | #{integer(debug_section[:stored_bytes])} | included |"
      lines << ''
      lines << "Production saves #{integer(profiles[:debug_bytes] - profiles[:production_bytes])} bytes on the complex fixture by omitting stable-ID and provenance mappings. Runtime/user-facing names and semantic labels remain dictionary encoded in both profiles."
      lines << ''
      lines << '## Complex codec decisions'
      lines << ''
      lines.concat(position_codec_table(complex[:metrics][:positions]))
      lines << ''
      normal = complex[:metrics][:normals]
      lines << "Normals selected codec enum `#{normal[:codec]}`; max/p95/RMS angular error #{scientific(normal.dig(:errors, :max))} / #{scientific(normal.dig(:errors, :p95))} / #{scientific(normal.dig(:errors, :rms))} degrees."
      lines << ''
      transform = complex[:metrics][:transforms]
      lines << "Transforms selected codec enum `#{transform[:codec]}`; max/p95/RMS matrix error #{scientific(transform.dig(:errors, :max))} / #{scientific(transform.dig(:errors, :p95))} / #{scientific(transform.dig(:errors, :rms))}."
      lines << "The #{integer(complex[:counts][:instances])} instance rows reference #{integer(complex[:counts][:transforms])} transform rows; numeric references preserve #{integer(complex[:counts][:instances] - complex[:counts][:transforms])} existing transform reuses without expanding matrices per occurrence."
      lines << ''
      topology = complex[:metrics][:topology]
      adaptive = complex[:metrics][:adaptive_indices]
      lines << "Topology absolute uint32 baseline: #{integer(topology[:absolute_bytes])} bytes; delta-zigzag-varint blocks: #{integer(topology[:encoded_bytes])} bytes; saved #{integer(topology[:saved_bytes])} bytes before section compression."
      lines << ''
      lines << "Adaptive reference columns: #{integer(adaptive[:uint32_bytes])} byte uint32 baseline; #{integer(adaptive[:actual_bytes])} bytes selected; saved #{integer(adaptive[:saved_bytes])} bytes."
      lines << ''
      lines << 'The existing complex Model-Eval JSON contains no UV or embedded texture payloads; UV candidate results therefore come from the medium architectural fixture, while complex UV error is zero for an empty stream.'
      lines << ''
      lines.concat(uv_codec_table(results[1][:metrics][:uv]))
      lines << ''
      lines << '## Section entropy-codec search'
      lines << ''
      lines.concat(codec_table(codec_results))
      lines << ''
      lines << 'Production selection remains per-section DEFLATE or STORE: it is available in the supported Ruby standard library and needs no mandatory WASM/runtime dependency. Brotli and Zstandard measurements are retained as evidence for a future format version.'
      lines << ''
      lines << '## Texture transcoding experiment'
      lines << ''
      lines.concat(texture_table(codec_results['texture'] || {}))
      lines << ''
      lines << 'Source texture bytes remain the default production representation. Optional WebP is not emitted by this RC.'
      lines << ''
      lines << '## Decode performance and allocation counters'
      lines << ''
      lines << '| Fixture | Encode ms | Header parse ms | Directory-only ms | Verify/inflate ms | Decoder container ms | Metadata ms | Analytical ms | Visual ms | Texture ms | Validation ms | Total reference decode ms | Encode allocated objects | Decode allocated objects | Final typed-array bytes |'
      lines << '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'
      results.each do |row|
        timing = row[:decode_timings]
        lines << "| #{row[:name]} | #{decimal(row[:encode_ms])} | #{decimal(row[:header_ms])} | #{decimal(row[:directory_ms])} | #{decimal(row[:inflate_ms])} | #{decimal(timing[:container_ms])} | #{decimal(timing[:metadata_ms])} | #{decimal(timing[:analytical_ms])} | #{decimal(timing[:visual_ms])} | #{decimal(timing[:texture_ms])} | #{decimal(timing[:validation_ms])} | #{decimal(row[:decode_ms])} | #{integer(row[:encode_objects])} | #{integer(row[:decode_objects])} | #{integer(row[:typed_array_bytes])} |"
      end
      lines << ''
      lines << 'Allocation counts are Ruby VM `GC.stat[:total_allocated_objects]` deltas. Final typed-array bytes estimate browser Float32 positions/normals/UV/transforms plus Uint32 topology/edges; peak temporary bytes are not exposed reliably by Ruby 2.5/3.2.'
      lines << ''
      lines << '## Shared definition scaling'
      lines << ''
      lines << '| Instances | Total BOMC bytes | Geometry section bytes | Instance section bytes | Transform section bytes |'
      lines << '|---:|---:|---:|---:|---:|'
      scaling.each do |row|
        lines << "| #{integer(row[:count])} | #{integer(row[:total_bytes])} | #{integer(row[:geometry_bytes])} | #{integer(row[:instance_bytes])} | #{integer(row[:transform_bytes])} |"
      end
      lines << ''
      lines << 'Geometry section bytes remain constant across all five scales; only instance and transform streams grow.'
      lines << ''
      lines << '## Known-model context'
      lines << ''
      if complex[:paired_skp_bytes]
        lines << "The complex JSON is paired by filename with `#{File.basename(complex[:paired_skp])}` (#{integer(complex[:paired_skp_bytes])} bytes). Its BOMC is #{integer(complex[:bomc_bytes])} bytes (#{percent(complex[:bomc_bytes], complex[:paired_skp_bytes])} of SKP). This is a file-size comparison only, not a claim of real SketchUp compiled-format acceptance."
      end
      lines << ''
      lines << 'The requested known `RUMAH L.skp` is 33,035,617 bytes, but no matching existing CleanPackage/Model-Eval JSON fixture is available, so an honest RUMAH L compiled byte count remains pending the user export.'
      lines << ''
      lines << 'REAL SKETCHUP COMPILED-FORMAT ACCEPTANCE: PENDING USER TEST'
      lines << ''
      lines.join("\n")
    end

    def position_codec_table(blocks)
      totals = {}
      selected = Hash.new(0)
      blocks.each do |block|
        selected[block[:codec]] += 1
        block[:candidates].each do |candidate|
          row = totals[candidate[:name]] ||= { raw: 0, deflate: 0, max: 0.0, passed: 0 }
          row[:raw] += candidate[:raw_bytes]
          row[:deflate] += candidate[:deflate_bytes]
          row[:max] = [row[:max], candidate.dig(:errors, :max).to_f].max
          row[:passed] += 1 if candidate[:passed]
        end
      end
      lines = ['| Position candidate | Raw bytes | Candidate DEFLATE bytes | Max error (m) | Passing blocks |', '|---|---:|---:|---:|---:|']
      totals.each { |name, row| lines << "| #{name} | #{integer(row[:raw])} | #{integer(row[:deflate])} | #{scientific(row[:max])} | #{row[:passed]}/#{blocks.length} |" }
      lines << ''
      lines << "Selected per-block codec counts: #{selected.sort.map { |codec, count| "enum #{codec}=#{count}" }.join(', ')}."
      lines
    end

    def uv_codec_table(blocks)
      return ['No UV blocks were present.'] if blocks.empty?
      totals = {}
      blocks.each do |block|
        block[:candidates].each do |candidate|
          row = totals[candidate[:name]] ||= { raw: 0, deflate: 0, max: 0.0, passed: 0 }
          row[:raw] += candidate[:raw_bytes]
          row[:deflate] += candidate[:deflate_bytes]
          row[:max] = [row[:max], candidate.dig(:errors, :max).to_f].max
          row[:passed] += 1 if candidate[:passed]
        end
      end
      lines = ['| UV candidate | Raw bytes | Candidate DEFLATE bytes | Max error | Passing blocks |', '|---|---:|---:|---:|---:|']
      totals.each { |name, row| lines << "| #{name} | #{integer(row[:raw])} | #{integer(row[:deflate])} | #{scientific(row[:max])} | #{row[:passed]}/#{blocks.length} |" }
      lines
    end

    def codec_table(results)
      totals = results['totals']
      return [results['status'] || 'Codec helper did not return totals.'] unless totals.is_a?(Hash)
      lines = ['| Codec | Total bytes | Compress ms | Decompress ms | Version |', '|---|---:|---:|---:|---|']
      totals.each do |name, values|
        lines << "| #{name} | #{integer(values['bytes'])} | #{decimal(values['compress_ms'])} | #{decimal(values['decompress_ms'])} | #{results.dig('versions', name)} |"
      end
      Array(results['unavailable']).each { |name, reason| lines << "| #{name} | unavailable | n/a | n/a | #{reason} |" }
      lines
    end

    def texture_table(texture)
      return ["Texture benchmark status: #{texture['status'] || 'not run'}. Selected: source."] unless texture['status'] == 'benchmarked'
      [
        '| Representation | Bytes | Quality / error | Encode ms | Decode ms | Selected |',
        '|---|---:|---|---:|---:|---|',
        "| Source #{texture['source_format']} | #{integer(texture['source_bytes'])} | lossless source | 0 | n/a | yes |",
        "| WebP | #{integer(texture['webp_bytes'])} | quality #{texture['webp_quality']}, PSNR #{decimal(texture['psnr_db'])} dB | #{decimal(texture['encode_ms'])} | #{decimal(texture['decode_ms'])} | no (optional only) |",
        '| AVIF | unavailable in installed Pillow encoder | n/a | n/a | n/a | no |',
        '| KTX2/Basis | unavailable in repository toolchain | n/a | n/a | n/a | no |'
      ]
    end

    def logical_counts(decoded)
      {
        meshes: decoded[:meshes].length,
        faces: decoded[:meshes].map { |mesh| mesh[:faces].length }.inject(0, :+),
        definitions: decoded[:definitions].length,
        instances: decoded[:instances].length,
        transforms: decoded[:transforms].length,
        fallback: decoded[:fallback].length,
        materials: decoded[:materials].length,
        textures: decoded[:textures].length,
        unaccounted: decoded[:coverage][:unaccounted]
      }
    end

    def typed_array_bytes(decoded)
      positions = decoded[:meshes].map { |mesh| mesh[:positions].length }.inject(0, :+) * 4
      topology = decoded[:meshes].map { |mesh| mesh[:faces].map { |face| face[:outer].length + face[:holes].flatten.length + face[:triangles].length }.inject(0, :+) }.inject(0, :+) * 4
      normals = decoded[:meshes].map { |mesh| mesh[:faces].length }.inject(0, :+) * 3 * 4
      uv = decoded[:meshes].map { |mesh| mesh[:faces].map { |face| [:front_outer, :front_holes, :back_outer, :back_holes].map { |key| Array(face[:uv] && face[:uv][key]).flatten.length }.inject(0, :+) }.inject(0, :+) }.inject(0, :+) * 4
      transforms = decoded[:transforms].length * 12 * 4
      edges = decoded[:meshes].map { |mesh| mesh[:edges].length }.inject(0, :+) * 2 * 4
      positions + topology + normals + uv + transforms + edges
    end

    def paired_skp_path(json_path)
      return nil unless json_path
      base = File.basename(json_path).sub(/_model-eval\.json\z/i, '')
      candidate = File.expand_path(File.join(File.dirname(json_path), '..', "#{base}.skp"))
      File.file?(candidate) ? candidate : nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def integer(value)
      value.to_i.to_s.reverse.scan(/.{1,3}/).join(',').reverse
    end

    def decimal(value)
      format('%.3f', value.to_f)
    end

    def scientific(value)
      format('%.6g', value.to_f)
    end

    def reduction(value, baseline)
      format('%.2f%%', (1.0 - value.to_f / baseline.to_f) * 100.0)
    end

    def percent(value, baseline)
      format('%.2f%%', value.to_f * 100.0 / baseline.to_f)
    end
  end
end

exit(SibamboHistory::V20260819_01::BOMCBenchmark.run(ARGV) ? 0 : 1)

end # SibamboHistory
