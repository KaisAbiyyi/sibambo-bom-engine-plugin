#!/usr/bin/env ruby
# Pure-Ruby BOMC 1.1 size and cooperative responsiveness benchmark.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative '../bomc_decoder'
require_relative '../bomc_processing'
require_relative '../bomc_validator'
require_relative '../bomc_writer'

module SibamboHistory
  module V20260829_01
  module BOMCCooperativeBenchmark
    module_function

    def run(argv)
      options = { output: File.expand_path('../../BOMC_COOPERATIVE_BENCHMARK.md', __dir__) }
      OptionParser.new { |parser| parser.on('--output PATH') { |value| options[:output] = File.expand_path(value) } }.parse!(argv)
      root = File.expand_path('../..', __dir__)
      fixtures = [
        fixture_from_json('TINY simple box', File.join(root, 'examples', 'model-eval-json-v1-small.json')),
        { name: 'SMALL texture-heavy synthetic', graph: small_graph, base_path: nil },
        fixture_from_json('MEDIUM architectural export', File.join(root, 'skps', 'model-eval-exports', 'presentation20__SBE-2026.08.29-01_model-eval.json')),
        fixture_from_json('COMPLEX existing export', File.join(root, 'skps', 'model-eval-exports', 'RUMAH Y__SBE-2026.08.29-01_model-eval.json'))
      ]
      sizes = fixtures.map { |fixture| measure_size(fixture) }
      stress = stress_graph(10_000)
      responsiveness = measure_responsiveness(stress)
      sha_values = responsiveness.reject { |row| row[:name] == 'Synchronous baseline' }.map { |row| row[:sha256] }.uniq
      raise 'Preset scheduling changed BOMC bytes.' unless sha_values.length == 1
      decoded = BOMCDecoder.decode(BOMCWriter.pack(stress, compression_level: 6)[:bytes])
      validation = BOMCValidator.validate!(stress, decoded)
      raise 'Stress fixture contains unaccounted geometry.' unless validation[:coverage][:unaccounted].zero?

      report = render_report(sizes, responsiveness, validation)
      File.open(options[:output], 'w:UTF-8') { |file| file.write(report) }
      puts "Wrote #{options[:output]}"
      sizes.each { |row| puts "#{row[:name]}: #{row[:old_bytes]} -> #{row[:new_bytes]} bytes" }
      responsiveness.each do |row|
        puts "#{row[:name]}: total=#{format('%.3f', row[:total_ms])}ms max_tick=#{format('%.3f', row[:max_tick_ms])}ms stage=#{row[:max_stage] || :whole_export} yields=#{row[:yields]} sha=#{row[:sha256]}"
      end
      true
    end

    def fixture_from_json(name, path)
      { name: name, graph: JSON.parse(File.read(path), symbolize_names: true), base_path: File.dirname(path) }
    end

    def measure_size(fixture)
      old = BOMCWriter.pack(
        fixture[:graph], profile: :production, base_path: fixture[:base_path],
        sparse: false, compact_directory: false, compression_level: 9
      )
      current = BOMCWriter.pack(
        fixture[:graph], profile: :production, base_path: fixture[:base_path],
        sparse: true, compact_directory: true, compression_level: 9
      )
      minimal = BOMCWriter.pack(
        fixture[:graph], profile: :production, base_path: fixture[:base_path],
        sparse: true, compact_directory: true, compression_level: 9, minimal_metadata: true
      )
      decoded = BOMCDecoder.decode(current[:bytes])
      validation = BOMCValidator.validate!(fixture[:graph], decoded)
      raise "#{fixture[:name]} contains unaccounted geometry." unless validation[:coverage][:unaccounted].zero?
      old_directory = BOMC::Container.read_directory(old[:bytes])
      new_directory = BOMC::Container.read_directory(current[:bytes])
      old_empty = old_directory[:sections].select { |section| section[:count].zero? }
      {
        name: fixture[:name], old_bytes: old[:bytes].bytesize, new_bytes: current[:bytes].bytesize,
        minimal_bytes: minimal[:bytes].bytesize, old_sections: old_directory[:sections].length,
        new_sections: new_directory[:sections].length, empty_sections_removed: old_empty.length,
        old_header_directory: old[:metrics][:header_directory_bytes],
        new_header_directory: current[:metrics][:header_directory_bytes],
        metadata_removed: current[:bytes].bytesize - minimal[:bytes].bytesize,
        texture_bytes: current.dig(:metrics, :textures, :bytes),
        sha256: current[:sha256], unaccounted: validation[:coverage][:unaccounted]
      }
    end

    def measure_responsiveness(graph)
      rows = []
      started = monotonic
      baseline = BOMCWriter.pack(graph, compression_level: 6)
      baseline_ms = (monotonic - started) * 1000.0
      rows << { name: 'Synchronous baseline', total_ms: baseline_ms, max_tick_ms: baseline_ms, yields: 0, sha256: baseline[:sha256], bytes: baseline[:bytes].bytesize }

      modes = [
        ['Batch=1', BOMCProcessing.settings(:custom, custom: { min_items: 1, max_items: 1, max_items_limit: 1, max_ms: 100.0 })],
        ['Light', BOMCProcessing.settings(:light)],
        ['Balanced', BOMCProcessing.settings(:balanced)],
        ['Fast', BOMCProcessing.settings(:fast)],
        ['Huge custom', BOMCProcessing.settings(:custom, custom: { min_items: 1, max_items: 32_768, max_items_limit: 32_768, max_ms: 100.0 })]
      ]
      modes.each do |name, settings|
        tick_started = monotonic
        max_tick = 0.0
        max_stage = :none
        yields = 0
        controller = BOMCProcessing::Controller.new(
          settings: settings,
          clock: -> { monotonic },
          on_yield: lambda do |event|
            if event[:elapsed_ms].to_f > max_tick
              max_tick = event[:elapsed_ms].to_f
              max_stage = event[:stage]
            end
            yields += 1
            tick_started = monotonic
          end,
          cancelled: -> { false }
        )
        started = monotonic
        result = BOMCWriter.pack(
          graph,
          compression_level: 6,
          checkpoint: ->(**event) { controller.checkpoint(**event) }
        )
        total_ms = (monotonic - started) * 1000.0
        trailing = (monotonic - tick_started) * 1000.0
        if trailing > max_tick
          max_tick = trailing
          max_stage = :finalize
        end
        rows << { name: name, total_ms: total_ms, max_tick_ms: max_tick, max_stage: max_stage, yields: yields, sha256: result[:sha256], bytes: result[:bytes].bytesize }
      end
      rows
    end

    def small_graph
      graph = base_graph
      texture = "\xff\xd8".b + Random.new(20_260_813).bytes(3 * 1024 * 1024)
      graph[:materials][0][:texture] = {
        bytes: texture, filename: 'efficient-source.jpg', image_width_px: 2048,
        image_height_px: 2048, width_m: 2.0, height_m: 2.0
      }
      graph
    end

    def stress_graph(instance_count)
      graph = base_graph
      graph[:materials][0][:texture] = {
        bytes: "\xff\xd8".b + Random.new(71).bytes(256 * 1024), filename: 'stress.jpg',
        image_width_px: 1024, image_height_px: 1024, width_m: 2.0, height_m: 2.0
      }
      graph[:definitions] << { id: 'definition-nested', name: 'Nested', kind: 'component_definition', mesh_id: nil, node_ids: [] }
      graph[:definitions][1][:node_ids] = ['node-nested']
      graph[:nodes] << {
        id: 'node-nested', kind: 'component_instance', name: 'Nested',
        owner_definition_id: 'definition-panel', definition_id: 'definition-nested',
        transform_id: 0, visible: true
      }
      instance_count.times do |index|
        transform_id = graph[:transforms].length
        graph[:transforms] << [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, (index % 100) * 4.0, (index / 100) * 3.0, 0, 1]
        node_id = "node-panel-#{index}"
        graph[:nodes] << {
          id: node_id, kind: 'component_instance', name: 'Panel',
          owner_definition_id: 'definition-root', definition_id: 'definition-panel',
          transform_id: transform_id, material_override_id: nil, tag_id: 'tag-architecture', visible: true,
          semantic: { label: 'Facade Panel', role: 'facade', source: 'instance_name' }
        }
        graph[:definitions][0][:node_ids] << node_id
      end
      graph
    end

    def base_graph
      identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
      {
        source: { file_name: 'synthetic.skp', model_name: 'Synthetic architectural fixture' },
        coordinate_system: { units: 'm', handedness: 'right', up_axis: 'Z' },
        materials: [{ id: 'material-brick', name: 'Brick', display_name: 'Brick', color: { r: 170, g: 80, b: 40, a: 255 }, opacity: 1.0 }],
        tags: [{ id: 'tag-architecture', name: 'Architecture', visible: true }],
        transforms: [identity],
        meshes: [{
          id: 'mesh-panel', definition_id: 'definition-panel',
          positions_m: [0, 0, 0, 4, 0, 0, 4, 3, 0, 0, 3, 0, 1, 1, 0, 1, 2, 0, 2, 2, 0, 2, 1, 0],
          faces: [{
            id: 'face-panel', outer: [0, 1, 2, 3], holes: [[4, 5, 6, 7]],
            triangles: [0, 1, 7, 0, 7, 4, 1, 2, 6, 1, 6, 7, 2, 3, 5, 2, 5, 6, 3, 0, 4, 3, 4, 5],
            front_material_id: 'material-brick', tag_id: 'tag-architecture', normal: [0, 0, 1],
            area_m2: 11.0, surface_hint: 'wall', hidden: false,
            semantic: { label: 'Facade Wall', role: 'wall', source: 'instance_name' },
            uv: {
              front_outer: [[-0.5, 0], [2.5, 0], [2.5, 1.5], [-0.5, 1.5]],
              front_holes: [[[0.25, 0.25], [0.25, 0.75], [0.75, 0.75], [0.75, 0.25]]],
              back_outer: [], back_holes: []
            }
          }],
          edges: [{ id: 'edge-panel', vertices: [0, 1], soft: false, smooth: false }]
        }],
        definitions: [
          { id: 'definition-root', name: 'Root', kind: 'model_definition', mesh_id: nil, node_ids: [] },
          { id: 'definition-panel', name: 'Panel', kind: 'component_definition', mesh_id: 'mesh-panel', node_ids: [] }
        ],
        nodes: [{ id: 'node-root', kind: 'root', name: 'Root', owner_definition_id: nil, definition_id: 'definition-root', transform_id: 0, visible: true }]
      }
    end

    def render_report(sizes, responsiveness, validation)
      lines = []
      lines << '# BOMC 1.1 Cooperative/Size Benchmark'
      lines << ''
      lines << 'Generated 2026-08-13 with pure Ruby detached fixtures. SketchUp was not launched or automated.'
      lines << ''
      lines << '## Corpus: BOMC 1.0 fixed/full vs BOMC 1.1 compact/sparse'
      lines << ''
      lines << '| Fixture | Old BOMC | New BOMC | Saved | Old sections | New sections | Empty removed | Header+directory old/new | Minimal metadata | Metadata removed | Texture bytes | Unaccounted |'
      lines << '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'
      sizes.each do |row|
        lines << "| #{row[:name]} | #{integer(row[:old_bytes])} | #{integer(row[:new_bytes])} | #{integer(row[:old_bytes] - row[:new_bytes])} | #{row[:old_sections]} | #{row[:new_sections]} | #{row[:empty_sections_removed]} | #{integer(row[:old_header_directory])} / #{integer(row[:new_header_directory])} | #{integer(row[:minimal_bytes])} | #{integer(row[:metadata_removed])} | #{integer(row[:texture_bytes])} | #{row[:unaccounted]} |"
      end
      lines << ''
      lines << 'The SMALL fixture embeds a deterministic 3 MiB already-efficient JPEG-like source. It is retained verbatim; structural savings come from the compact directory and absent empty streams, not quality loss.'
      lines << ''
      lines << '## Responsiveness and preset determinism (10,000 shared/nested instances)'
      lines << ''
      lines << '| Mode | Total ms | Maximum uninterrupted interval ms | Max stage | Yield count | Bytes | SHA256 |'
      lines << '|---|---:|---:|---|---:|---:|---|'
      responsiveness.each do |row|
        lines << "| #{row[:name]} | #{decimal(row[:total_ms])} | #{decimal(row[:max_tick_ms])} | #{row[:max_stage] || :whole_export} | #{row[:yields]} | #{integer(row[:bytes])} | `#{row[:sha256]}` |"
      end
      lines << ''
      sha = responsiveness[1][:sha256]
      lines << "All scheduled modes emitted byte-identical BOMC: **PASS** (`#{sha}`). The processing mode changes only checkpoint/yield frequency."
      lines << ''
      lines << "Stress differential validation: unaccounted=#{validation[:coverage][:unaccounted]}, topology exact=#{validation[:topology][:exact]}, textures exact=#{validation[:textures][:exact]}."
      lines << ''
      lines << 'Maximum intervals include indivisible codec/DEFLATE calls and are therefore an honest upper bound for current cooperative work. Live SketchUp responsiveness remains pending user testing.'
      lines << ''
      lines.join("\n")
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
  end
end

exit(SibamboHistory::V20260829_01::BOMCCooperativeBenchmark.run(ARGV) ? 0 : 1)

end # SibamboHistory
