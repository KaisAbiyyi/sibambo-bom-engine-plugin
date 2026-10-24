# Independent logical differential validator for BOMC fixtures and exports.

require_relative 'bomc_format'
require_relative 'scene_visibility_resolver'
require_relative 'bomc_model_adapter'
require_relative 'bomc_geometry_policy'
require_relative 'bomc_texture_policy'
require_relative 'bomc_texture_optimizer'

module BOMEngine
  module BOMCValidator
    class ProfileValidationError < StandardError
      attr_reader :report

      def initialize(message, report: nil)
        super(message)
        @report = report
      end
    end
    DEFAULT_TOLERANCES = {
      position_m: 0.001,
      normal_deg: 0.1,
      uv: 1.0e-4,
      transform: 1.0e-5,
      area_relative: 0.001,
      area_absolute_m2: 1.0e-6
    }.freeze

    class ErrorAccumulator
      def initialize(max_count: 0, percentile: true)
        @count = 0
        @max = 0.0
        @sum_squares = 0.0
        @percentile = percentile
        upper = [Integer(max_count || 0), 0].max
        @tail_capacity = percentile && upper.positive? ? [upper - (upper * 0.95).ceil + 1, 1].max : 0
        @tail = []
      end

      def add(value)
        numeric = value.to_f
        @count += 1
        @max = numeric if numeric > @max
        @sum_squares += numeric * numeric
        add_tail(numeric) if @tail_capacity.positive?
        numeric
      end

      def summary
        return { max: 0.0, p95: 0.0, rms: 0.0 } if @count.zero?
        p95 = @max
        if @percentile && !@tail.empty?
          rank_from_largest = @count - (@count * 0.95).ceil + 1
          ordered = @tail.sort.reverse
          p95 = ordered[[rank_from_largest - 1, ordered.length - 1].min]
        end
        {
          max: @max,
          p95: p95,
          rms: Math.sqrt(@sum_squares / @count)
        }
      end

      private

      def add_tail(value)
        if @tail.length < @tail_capacity
          @tail << value
          sift_up(@tail.length - 1)
          return
        end
        return unless value > @tail[0]
        @tail[0] = value
        sift_down(0)
      end

      def sift_up(index)
        while index.positive?
          parent = (index - 1) / 2
          break if @tail[parent] <= @tail[index]
          @tail[parent], @tail[index] = @tail[index], @tail[parent]
          index = parent
        end
      end

      def sift_down(index)
        length = @tail.length
        loop do
          left = index * 2 + 1
          break if left >= length
          right = left + 1
          child = right < length && @tail[right] < @tail[left] ? right : left
          break if @tail[index] <= @tail[child]
          @tail[index], @tail[child] = @tail[child], @tail[index]
          index = child
        end
      end
    end

    def self.compare(source, decoded, tolerances: {}, base_path: nil, normalized_source: nil)
      normalized = normalized_source || BOMC::ModelAdapter.normalize(source, base_path: base_path)
      limits = DEFAULT_TOLERANCES.merge(tolerances)
      face_count = normalized[:meshes].inject(0) { |sum, mesh| sum + mesh[:faces].length }
      position_count = normalized[:meshes].inject(0) { |sum, mesh| sum + (mesh[:positions].length / 3) }
      uv_count = normalized[:meshes].inject(0) do |sum, mesh|
        sum + mesh[:faces].inject(0) { |face_sum, face| face_sum + [nested_scalar_count(face[:uv]) / 2, 1].max }
      end
      position_errors = ErrorAccumulator.new(max_count: position_count)
      normal_errors = ErrorAccumulator.new(max_count: face_count)
      uv_errors = ErrorAccumulator.new(max_count: uv_count)
      transform_errors = ErrorAccumulator.new(max_count: normalized[:transforms].length)
      area_errors = ErrorAccumulator.new(max_count: face_count)
      topology_exact = normalized[:meshes].length == decoded[:meshes].length
      visual_edges_exact = topology_exact
      materials_exact = compare_materials(normalized[:materials], decoded[:materials], decoded[:textures])
      tags_exact = normalized[:tags].each_with_index.all? do |tag, index|
        row = decoded[:tags][index]
        row && tag[:name].to_s == row[:name].to_s && tag[:visible] == row[:visible]
      end && normalized[:tags].length == decoded[:tags].length
      definitions_exact = normalized[:definitions].each_with_index.all? do |definition, index|
        row = decoded[:definitions][index]
        row && definition[:name].to_s == row[:name].to_s && definition[:kind].to_s == row[:kind].to_s && definition[:mesh] == row[:mesh]
      end && normalized[:definitions].length == decoded[:definitions].length
      instances_exact = normalized[:instances].each_with_index.all? do |instance, index|
        row = decoded[:instances][index]
        row &&
          instance[:name].to_s == row[:name].to_s &&
          instance[:kind].to_s == row[:kind].to_s &&
          instance[:owner_definition] == row[:owner_definition] &&
          instance[:definition] == row[:definition] &&
          instance[:transform] == row[:transform] &&
          instance[:material] == row[:material] &&
          instance[:tag] == row[:tag] &&
          instance[:visible] == row[:visible] &&
          normalize_role(instance[:semantic_role]) == row[:semantic_role].to_s &&
          optional_string(instance[:semantic_label]) == optional_string(row[:semantic_label])
      end && normalized[:instances].length == decoded[:instances].length
      fallback_exact = compare_fallback(normalized[:instances], decoded[:fallback], decoded[:textures])

      normalized[:meshes].each_with_index do |source_mesh, mesh_index|
        decoded_mesh = decoded[:meshes][mesh_index]
        unless decoded_mesh
          topology_exact = false
          visual_edges_exact = false
          next
        end
        each_point_error(source_mesh[:positions], decoded_mesh[:positions]) { |error| position_errors.add(error) }
        topology_exact &&= source_mesh[:faces].length == decoded_mesh[:faces].length
        source_mesh[:faces].each_with_index do |source_face, face_index|
          decoded_face = decoded_mesh[:faces][face_index]
          unless decoded_face
            topology_exact = false
            next
          end
          topology_exact &&= source_face[:outer] == decoded_face[:outer]
          topology_exact &&= source_face[:holes] == decoded_face[:holes]
          topology_exact &&= source_face[:triangles] == decoded_face[:triangles]
          topology_exact &&= source_face[:front_material] == decoded_face[:front_material]
          topology_exact &&= source_face[:back_material] == decoded_face[:back_material]
          topology_exact &&= source_face[:front_appearance_required] == decoded_face[:front_appearance_required]
          topology_exact &&= source_face[:back_appearance_required] == decoded_face[:back_appearance_required]
          topology_exact &&= source_face[:tag] == decoded_face[:tag]
          topology_exact &&= normalize_surface(source_face[:surface_type]) == decoded_face[:surface_type].to_s
          topology_exact &&= normalize_role(source_face[:semantic_role]) == decoded_face[:semantic_role].to_s
          topology_exact &&= optional_string(source_face[:semantic_label]) == optional_string(decoded_face[:semantic_label])
          topology_exact &&= source_face[:hidden] == decoded_face[:hidden]
          normal_errors.add(angular_error(source_face[:normal], decoded_face[:normal]))
          source_uv = flatten_uv(source_face[:uv])
          decoded_uv = flatten_uv(decoded_face[:uv])
          if source_uv.length == decoded_uv.length
            each_pair_error(source_uv, decoded_uv) { |error| uv_errors.add(error) }
          else
            uv_errors.add(Float::INFINITY)
          end
          area_errors.add((source_face[:area_m2].to_f - decoded_face[:area_m2].to_f).abs)
        end
        source_edges = source_mesh[:edges].map { |edge| [edge[:vertices], edge[:tag], edge[:hidden], edge[:soft], edge[:smooth]] }
        decoded_edges = decoded_mesh[:edges].map { |edge| [edge[:vertices], edge[:tag], edge[:hidden], edge[:soft], edge[:smooth]] }
        visual_edges_exact &&= source_edges == decoded_edges
      end

      normalized[:transforms].each_with_index do |matrix, index|
        decoded_matrix = decoded[:transforms][index]
        if decoded_matrix
          max_error = 0.0
          matrix.each_with_index do |value, component|
            error = (value.to_f - decoded_matrix[component].to_f).abs
            max_error = error if error > max_error
          end
          transform_errors.add(max_error)
        else
          transform_errors.add(Float::INFINITY)
        end
      end
      position_summary = position_errors.summary
      normal_summary = normal_errors.summary
      uv_summary = uv_errors.summary
      transform_summary = transform_errors.summary
      area_summary = area_errors.summary
      source_texture_hashes = normalized[:materials].map { |material| material[:texture] && material[:texture][:sha256] }
      source_texture_hashes += normalized[:instances].map { |instance| instance.dig(:fallback, :texture, :sha256) }
      source_texture_hashes = source_texture_hashes.compact.uniq.sort
      decoded_texture_hashes = decoded[:textures].map { |texture| texture[:sha256] }.sort
      counts = {
        materials: [normalized[:materials].length, decoded[:materials].length],
        tags: [normalized[:tags].length, decoded[:tags].length],
        meshes: [normalized[:meshes].length, decoded[:meshes].length],
        faces: [normalized[:meshes].map { |mesh| mesh[:faces].length }.inject(0, :+), decoded[:meshes].map { |mesh| mesh[:faces].length }.inject(0, :+)],
        definitions: [normalized[:definitions].length, decoded[:definitions].length],
        instances: [normalized[:instances].length, decoded[:instances].length],
        transforms: [normalized[:transforms].length, decoded[:transforms].length],
        textures: [source_texture_hashes.length, decoded_texture_hashes.length]
      }
      counts[:exact] = counts.reject { |key, _value| key == :exact }.values.all? { |pair| pair[0] == pair[1] }
      maximum_area_tolerance = limits[:area_absolute_m2]
      normalized[:meshes].each do |mesh|
        mesh[:faces].each do |face|
          tolerance = [limits[:area_absolute_m2], face[:area_m2].to_f.abs * limits[:area_relative]].max
          maximum_area_tolerance = tolerance if tolerance > maximum_area_tolerance
        end
      end

      {
        counts: counts,
        materials: { exact: materials_exact },
        tags: { exact: tags_exact },
        definitions: { exact: definitions_exact },
        instances: { exact: instances_exact },
        fallback: { exact: fallback_exact },
        positions: {
          max_error_m: position_summary[:max], p95_error_m: position_summary[:p95], rms_error_m: position_summary[:rms],
          passed: position_summary[:max] <= limits[:position_m] + 1.0e-12
        },
        topology: { exact: topology_exact },
        normals: {
          max_angular_error_deg: normal_summary[:max], p95_angular_error_deg: normal_summary[:p95], rms_angular_error_deg: normal_summary[:rms],
          passed: normal_summary[:max] <= limits[:normal_deg] + 1.0e-12
        },
        uv: {
          max_error: uv_summary[:max], p95_error: uv_summary[:p95], rms_error: uv_summary[:rms],
          passed: uv_summary[:max] <= limits[:uv] + 1.0e-12
        },
        transforms: {
          max_error: transform_summary[:max], p95_error: transform_summary[:p95], rms_error: transform_summary[:rms],
          passed: transform_summary[:max] <= limits[:transform] + 1.0e-12
        },
        areas: {
          max_error_m2: area_summary[:max], p95_error_m2: area_summary[:p95], rms_error_m2: area_summary[:rms],
          tolerance_m2: maximum_area_tolerance,
          passed: area_summary[:max] <= maximum_area_tolerance + 1.0e-12
        },
        visual_edges: { exact: visual_edges_exact },
        textures: { exact: source_texture_hashes == decoded_texture_hashes, hashes: decoded_texture_hashes },
        coverage: decoded[:coverage]
      }
    end

    def self.validate!(source, decoded, tolerances: {}, base_path: nil, normalized_source: nil)
      result = compare(source, decoded, tolerances: tolerances, base_path: base_path, normalized_source: normalized_source)
      failures = []
      failures << 'table counts' unless result[:counts][:exact]
      failures << 'materials' unless result[:materials][:exact]
      failures << 'tags' unless result[:tags][:exact]
      failures << 'definitions' unless result[:definitions][:exact]
      failures << 'instances' unless result[:instances][:exact]
      failures << 'fallback' unless result[:fallback][:exact]
      failures << 'topology' unless result[:topology][:exact]
      failures << 'positions' unless result[:positions][:passed]
      failures << 'normals' unless result[:normals][:passed]
      failures << 'UV' unless result[:uv][:passed]
      failures << 'transforms' unless result[:transforms][:passed]
      failures << 'areas' unless result[:areas][:passed]
      failures << 'visual edges' unless result[:visual_edges][:exact]
      failures << 'textures' unless result[:textures][:exact]
      failures << 'coverage' unless result[:coverage][:unaccounted].to_i.zero?
      raise "BOMC differential validation failed: #{failures.join(', ')}." unless failures.empty?

      result
    end

    def self.validate_profile(source:, decoded:, profile: :visual, texture_evidence: nil, base_path: nil, normalized_source: nil, checkpoint: nil)
      processed = 0
      work_cursor = if checkpoint
        SceneVisibilityResolver::WorkCursor.new(on_checkpoint: lambda do |event|
          processed += event[:work_units]
          checkpoint.call(stage: :validate, processed: processed, total: 0,
            force: event[:force], operation_label: event[:operation_label], unit: 'validation work')
        end)
      end
      work_cursor&.flush('fidelity_validation')
      normalized = if normalized_source
                     normalized_source
                   elsif source.is_a?(Hash) && source[:meshes] && source[:instances] && !source.dig(:format, :name).to_s.include?('BOM Engine Canonical')
                     source
                   else
                     BOMC::ModelAdapter.normalize(source, base_path: base_path)
                   end

      prof = profile.to_s.downcase.to_sym
      prof = :visual unless [:exact, :research, :visual].include?(prof)

      case prof
      when :exact
        pos_limit = 1.0e-12
        norm_limit = 1.0e-12
        uv_limit = 1.0e-12
        transform_limit = 1.0e-12
        area_limit_relative = 0.0
        area_limit_abs = 1.0e-9
      when :research
        pos_limit = 0.0005
        norm_limit = 0.10
        uv_limit = 1.0e-4
        transform_limit = 1.0e-5
        area_limit_relative = 0.001
        area_limit_abs = 1.0e-6
      when :visual
        pos_limit = 0.0020
        norm_limit = 0.50
        uv_limit = 5.0e-4
        transform_limit = 1.0e-5
        area_limit_relative = 0.005
        area_limit_abs = 1.0e-4
      end

      failures = []

      counts_match = (normalized[:tags].length == decoded[:tags].length) &&
                     (normalized[:definitions].length == decoded[:definitions].length) &&
                     (normalized[:instances].length == decoded[:instances].length) &&
                     (normalized[:meshes].length == decoded[:meshes].length) &&
                     (normalized[:transforms].length == decoded[:transforms].length)
      failures << 'table counts' unless counts_match

      materials_exact = compare_materials_profile(normalized[:materials], decoded[:materials])
      failures << 'materials' unless materials_exact

      tags_exact = (normalized[:tags].length == decoded[:tags].length) &&
                   normalized[:tags].each_with_index.all? do |tag, index|
                     row = decoded[:tags][index]
                     row && tag[:name].to_s == row[:name].to_s && tag[:visible] == row[:visible]
                   end
      failures << 'tags' unless tags_exact

      definitions_exact = (normalized[:definitions].length == decoded[:definitions].length) &&
                          normalized[:definitions].each_with_index.all? do |definition, index|
                            row = decoded[:definitions][index]
                            row && definition[:name].to_s == row[:name].to_s &&
                              definition[:kind].to_s == row[:kind].to_s &&
                              definition[:mesh] == row[:mesh]
                          end
      failures << 'definitions' unless definitions_exact

      instances_exact = (normalized[:instances].length == decoded[:instances].length) &&
                        normalized[:instances].each_with_index.all? do |instance, index|
                          row = decoded[:instances][index]
                          row &&
                            instance[:name].to_s == row[:name].to_s &&
                            instance[:kind].to_s == row[:kind].to_s &&
                            instance[:owner_definition] == row[:owner_definition] &&
                            instance[:definition] == row[:definition] &&
                            instance[:transform] == row[:transform] &&
                            instance[:material] == row[:material] &&
                            instance[:tag] == row[:tag] &&
                            instance[:visible] == row[:visible]
                        end
      failures << 'instances' unless instances_exact

      # Semantics verification (both instances and faces)
      instance_semantics_exact = (normalized[:instances].length == decoded[:instances].length) &&
                                 normalized[:instances].each_with_index.all? do |instance, index|
                                   row = decoded[:instances][index]
                                   row &&
                                     normalize_role(instance[:semantic_role]) == row[:semantic_role].to_s &&
                                     optional_string(instance[:semantic_label]) == optional_string(row[:semantic_label])
                                 end

      face_semantics_exact = true
      normalized[:meshes].each_with_index do |mesh, m_idx|
        work_cursor&.step('fidelity_validation')
        dec_mesh = decoded[:meshes][m_idx]
        unless dec_mesh
          face_semantics_exact = false
          next
        end
        mesh[:faces].each_with_index do |face, f_idx|
          work_cursor&.step('fidelity_validation')
          dec_face = dec_mesh[:faces][f_idx]
          unless dec_face &&
                 normalize_role(face[:semantic_role]) == dec_face[:semantic_role].to_s &&
                 optional_string(face[:semantic_label]) == optional_string(dec_face[:semantic_label])
            face_semantics_exact = false
          end
        end
      end
      semantics_exact = instance_semantics_exact && face_semantics_exact
      failures << 'semantics' unless semantics_exact

      # Geometry, topology and visual edges
      topology_exact = normalized[:meshes].length == decoded[:meshes].length
      visual_edges_exact = topology_exact
      position_errors = ErrorAccumulator.new(percentile: false)
      normal_errors = ErrorAccumulator.new(percentile: false)
      uv_errors = ErrorAccumulator.new(percentile: false)
      area_errors = ErrorAccumulator.new(percentile: false)
      positions_passed = true
      normals_passed = true
      uv_passed = true
      source_area_metadata_errors = ErrorAccumulator.new(percentile: false)
      source_area_metadata_mismatch_count = 0
      maximum_area_tolerance = area_limit_abs

      normalized[:meshes].each_with_index do |source_mesh, mesh_index|
        work_cursor&.step('fidelity_validation')
        decoded_mesh = decoded[:meshes][mesh_index]
        unless decoded_mesh
          topology_exact = false
          visual_edges_exact = false
          positions_passed = false
          next
        end

        # Exact/Research bounds are class-independent; do not allocate and
        # classify an entire large face table for a value those profiles ignore.
        mesh_class = BOMCGeometryPolicy.mesh_semantic_class(source_mesh[:faces]) if prof == :visual
        mesh_pos_tol = (prof == :visual) ? BOMCGeometryPolicy.position_tolerance(profile: :visual, semantic_class: mesh_class) : pos_limit

        each_point_error(source_mesh[:positions], decoded_mesh[:positions], work_cursor) do |error|
          position_errors.add(error)
          positions_passed = false if error > mesh_pos_tol + 1.0e-12
        end

        topology_exact &&= (source_mesh[:faces].length == decoded_mesh[:faces].length)
        source_mesh[:faces].each_with_index do |source_face, face_index|
          work_cursor&.step('fidelity_validation')
          decoded_face = decoded_mesh[:faces][face_index]
          unless decoded_face
            topology_exact = false
            normals_passed = false
            uv_passed = false
            next
          end

          topology_exact &&= source_face[:outer] == decoded_face[:outer]
          topology_exact &&= source_face[:holes] == decoded_face[:holes]
          topology_exact &&= source_face[:triangles] == decoded_face[:triangles]
          topology_exact &&= source_face[:front_material] == decoded_face[:front_material]
          topology_exact &&= source_face[:back_material] == decoded_face[:back_material]
          topology_exact &&= source_face[:tag] == decoded_face[:tag]
          topology_exact &&= normalize_surface(source_face[:surface_type]) == decoded_face[:surface_type].to_s
          topology_exact &&= source_face[:hidden] == decoded_face[:hidden]

          face_class = BOMCGeometryPolicy.classify_role(source_face[:semantic_role])
          face_norm_tol = (prof == :visual) ? BOMCGeometryPolicy.normal_tolerance(profile: :visual, semantic_class: face_class) : norm_limit
          face_uv_tol = (prof == :visual) ? BOMCGeometryPolicy.uv_tolerance(profile: :visual, semantic_class: face_class) : uv_limit

          ang_err = angular_error(source_face[:normal], decoded_face[:normal])
          normal_errors.add(ang_err)
          normals_passed &&= (ang_err <= face_norm_tol + 1.0e-12)
          normals_passed &&= source_face[:normal] == decoded_face[:normal] if prof == :exact

          source_uv = flatten_uv(source_face[:uv])
          decoded_uv = flatten_uv(decoded_face[:uv])
          if source_uv.length == decoded_uv.length
            each_pair_error(source_uv, decoded_uv, work_cursor) do |error|
              uv_errors.add(error)
              uv_passed = false if error > face_uv_tol + 1.0e-12
            end
          else
            uv_errors.add(Float::INFINITY)
            uv_passed = false
          end

          # BOMC stores positions/topology, not SketchUp's separately measured
          # area scalar. Exact must compare the geometry before/after encoding;
          # rounding/quantization already present in the input is not codec loss.
          reference_area = source_face[:area_m2].to_f
          if prof == :exact
            reference_area = geometry_face_area(source_mesh[:positions], source_face, work_cursor)
            metadata_error = (source_face[:area_m2].to_f - reference_area).abs
            source_area_metadata_errors.add(metadata_error)
            source_area_metadata_mismatch_count += 1 if metadata_error > area_limit_abs + 1.0e-12
          end
          area_errors.add((reference_area - decoded_face[:area_m2].to_f).abs)
          area_tolerance = [area_limit_abs, source_face[:area_m2].to_f.abs * area_limit_relative].max
          maximum_area_tolerance = area_tolerance if area_tolerance > maximum_area_tolerance
        end

        source_edges = source_mesh[:edges].map do |edge|
          work_cursor&.step('fidelity_edges')
          [edge[:vertices], edge[:tag], edge[:hidden], edge[:soft], edge[:smooth]]
        end
        decoded_edges = decoded_mesh[:edges].map do |edge|
          work_cursor&.step('fidelity_edges')
          [edge[:vertices], edge[:tag], edge[:hidden], edge[:soft], edge[:smooth]]
        end
        visual_edges_exact &&= (source_edges == decoded_edges)
      end

      failures << 'topology' unless topology_exact
      failures << 'visual edges' unless visual_edges_exact
      failures << 'positions' unless positions_passed
      failures << 'normals' unless normals_passed
      failures << 'UV' unless uv_passed

      # Transforms
      transform_errors = ErrorAccumulator.new(percentile: false)
      transforms_passed = true
      normalized[:transforms].each_with_index do |matrix, index|
        work_cursor&.step('fidelity_validation')
        decoded_matrix = decoded[:transforms][index]
        if decoded_matrix
          err = 0.0
          matrix.each_with_index do |value, component|
            work_cursor&.step('fidelity_validation')
            component_error = (value.to_f - decoded_matrix[component].to_f).abs
            err = component_error if component_error > err
          end
          transform_errors.add(err)
          transforms_passed = false if err > transform_limit + 1.0e-12
        else
          transform_errors.add(Float::INFINITY)
          transforms_passed = false
        end
      end
      failures << 'transforms' unless transforms_passed

      # Areas
      area_summary = area_errors.summary
      areas_passed = area_summary[:max] <= maximum_area_tolerance + 1.0e-12
      failures << 'areas' unless areas_passed

      # Scenes
      source_scenes = normalized[:scenes] || []
      decoded_scenes = decoded[:scenes] || []
      scenes_exact = true
      if source_scenes.any?
        if source_scenes.length != decoded_scenes.length
          scenes_exact = false
        else
          source_scenes.each_with_index do |src_s, s_i|
            work_cursor&.step('fidelity_validation')
            dec_s = decoded_scenes[s_i]
            unless dec_s && src_s[:name].to_s == dec_s[:name].to_s
              scenes_exact = false
              next
            end
            src_tags = Array(src_s[:tag_visibility] || src_s[:visible_tags]).map(&:to_s).sort
            dec_tags = Array(dec_s[:tag_visibility] || dec_s[:visible_tags]).map(&:to_s).sort
            scenes_exact &&= (src_tags == dec_tags)

            src_hidden = Array(src_s[:hidden_instances] || src_s[:hidden_nodes]).map(&:to_s).sort
            dec_hidden = Array(dec_s[:hidden_instances] || dec_s[:hidden_nodes]).map(&:to_s).sort
            scenes_exact &&= (src_hidden == dec_hidden)

            if src_s[:visibility_mask] && dec_s[:visibility_mask]
              scenes_exact &&= (src_s[:visibility_mask] == dec_s[:visibility_mask])
            end
            if src_s[:hidden_faces] && dec_s[:hidden_faces]
              scenes_exact &&= (src_s[:hidden_faces] == dec_s[:hidden_faces])
            end
            if src_s[:hidden_edges] && dec_s[:hidden_edges]
              scenes_exact &&= (src_s[:hidden_edges] == dec_s[:hidden_edges])
            end
          end
        end
      end
      failures << 'scenes' unless scenes_exact

      # Clip planes
      source_planes = normalized[:clip_planes] || []
      decoded_planes = decoded[:clip_planes] || []
      clip_planes_exact = true
      if source_planes.any?
        if source_planes.length != decoded_planes.length
          clip_planes_exact = false
        else
          source_planes.each_with_index do |src_p, p_i|
            work_cursor&.step('fidelity_validation')
            dec_p = decoded_planes[p_i]
            unless dec_p
              clip_planes_exact = false
              next
            end
            src_origin = Array(src_p[:origin_m] || src_p[:origin]).map(&:to_f)
            dec_origin = Array(dec_p[:origin_m] || dec_p[:origin]).map(&:to_f)
            src_normal = Array(src_p[:normal]).map(&:to_f)
            dec_normal = Array(dec_p[:normal]).map(&:to_f)
            tol = (prof == :exact) ? 1.0e-12 : 1.0e-5
            origin_err = 3.times.map { |i| (src_origin[i].to_f - dec_origin[i].to_f).abs }.max || 0.0
            norm_err = 3.times.map { |i| (src_normal[i].to_f - dec_normal[i].to_f).abs }.max || 0.0
            clip_planes_exact &&= (origin_err <= tol && norm_err <= tol && src_p[:keep_side].to_i == dec_p[:keep_side].to_i)
          end
        end
      end
      failures << 'clip planes' unless clip_planes_exact

      # Coverage
      unaccounted = decoded.dig(:coverage, :unaccounted).to_i
      coverage_passed = unaccounted.zero?
      failures << 'coverage' unless coverage_passed

      # Textures
      textures_passed = true
      texture_failures = []
      evidence_list = []
      if texture_evidence.is_a?(Array)
        evidence_list = texture_evidence
      elsif texture_evidence.is_a?(Hash)
        evidence_list = texture_evidence.values
      elsif normalized[:materials]
        normalized[:materials].each do |m|
          work_cursor&.step('fidelity_validation')
          ev = m.dig(:texture, :encoding_evidence) || m.dig(:texture, :staging_evidence)
          evidence_list << ev if ev
        end
      end

      evidence_list.compact.each_with_index do |ev, ev_i|
        work_cursor&.step('fidelity_validation')
        ev = ev[:staging] if ev.dig(:staging, :policy_revision)
        if ev[:policy_revision]
          quality = ev[:quality] || {}
          mse = quality[:mean_squared_error]
          max_error = quality[:max_channel_error]
          psnr = quality[:psnr_db]
          lossless = mse == 0.0 && max_error == 0
          measured = quality[:compatible] == true && quality[:alpha_preserved] == true &&
            ev[:alpha_preserved] == true && mse.is_a?(Numeric) && mse.finite? && mse >= 0 &&
            max_error.is_a?(Numeric) && max_error.finite? && max_error >= 0
          floor = BOMCTexturePolicy.min_psnr(profile: prof, semantic_class: ev[:semantic_class] || :class_b, native_jpeg: !!ev[:native_jpeg])
          passing_quality = lossless || (prof != :exact && psnr.is_a?(Numeric) && psnr.finite? && psnr >= floor)
          unless measured && passing_quality && ev[:profile].to_s == prof.to_s
            textures_passed = false
            texture_failures << "texture #{ev_i} invalid adaptive quality evidence"
          end
        end
        if ev[:reference] && ev[:candidate]
          comp = BOMCTextureOptimizer.compare(ev[:reference], ev[:candidate])
          if !comp[:compatible]
            textures_passed = false
            texture_failures << "texture #{ev_i} incompatible: #{comp[:reason]}"
          elsif prof == :exact
            if comp[:max_channel_error].to_i > 0 || comp[:mean_squared_error].to_f > 0.0
              textures_passed = false
              texture_failures << "texture #{ev_i} pixel error in exact profile"
            end
          else
            psnr = comp[:psnr_db].to_f
            klass = ev[:semantic_class] || :class_b
            is_native = !!ev[:native_jpeg]
            min_q = BOMCTexturePolicy.min_psnr(profile: prof, semantic_class: klass, native_jpeg: is_native)
            if psnr < min_q
              textures_passed = false
              texture_failures << "texture #{ev_i} PSNR #{psnr.round(1)} dB < threshold #{min_q} dB"
            end
          end
        elsif ev[:quality] && ev[:quality][:psnr_db]
          psnr = ev[:quality][:psnr_db].to_f
          klass = ev[:semantic_class] || :class_b
          is_native = !!ev[:native_jpeg]
          min_q = BOMCTexturePolicy.min_psnr(profile: prof, semantic_class: klass, native_jpeg: is_native)
          if prof == :exact
            if psnr < Float::INFINITY && !is_native
              textures_passed = false
              texture_failures << "texture #{ev_i} not lossless in exact profile"
            end
          elsif psnr < min_q
            textures_passed = false
            texture_failures << "texture #{ev_i} PSNR #{psnr.round(1)} dB < threshold #{min_q} dB"
          end
        end

        if ev[:has_alpha] || ev[:opaque] == false || ev[:alpha_preserved] == false
          if ev[:selected] == :jpeg_candidate || ev[:media_type] == :jpeg || (ev[:path] && ev[:path].downcase.end_with?('.jpg', '.jpeg'))
            textures_passed = false
            texture_failures << "texture #{ev_i} with alpha transcoded to JPEG"
          end
        end

        if prof == :exact && ev[:selected] == :jpeg_candidate && !ev[:native_jpeg]
          textures_passed = false
          texture_failures << "texture #{ev_i} transcoded to JPEG in exact profile"
        end
      end

      if prof == :exact
        Array(decoded[:textures]).each_with_index do |tex, t_i|
          work_cursor&.step('fidelity_validation')
          if tex[:media_type] == :jpeg_color_map
            map = BOMCJpegColorMap.parse(tex[:bytes])
            verified = evidence_list.compact.any? do |outer|
              ev = outer.dig(:staging, :policy_revision) ? outer[:staging] : outer
              q = ev[:quality] || {}
              ['exact-jcm-1', 'exact-jcm-2'].include?(ev[:policy_revision]) && ev[:selected] == :jpeg_color_map_candidate &&
                ev[:profile].to_s == 'exact' && ev[:required_loader] == 'bomc-next-jcm-v1' &&
                ev[:selected_sha256] == tex[:sha256] &&
                ev[:base_pixel_sha256] == map[:base_hash].unpack1('H*') &&
                ev[:output_pixel_sha256] == map[:output_hash].unpack1('H*') &&
                ev[:normalized_jpeg_sha256] == Digest::SHA256.hexdigest(map[:jpeg]) &&
                ev[:alpha_preserved] == true && q[:compatible] == true && q[:alpha_preserved] == true &&
                q[:mean_squared_error] == 0.0 && q[:max_channel_error] == 0
            end
            unless verified
              textures_passed = false
              texture_failures << "decoded texture #{t_i} has no digest-bound color-map pixel evidence"
            end
          end
          is_jpeg = [:jpeg, 'jpeg', 'image/jpeg'].include?(tex[:media_type]) || (tex[:filename] && tex[:filename].downcase.end_with?('.jpg', '.jpeg'))
          if is_jpeg
            # Decoded texture identity is its digest, not an optional filename.
            # Never let a different material's JPEG evidence certify this blob.
            verified = evidence_list.compact.any? do |outer|
              ev = outer.dig(:staging, :policy_revision) ? outer[:staging] : outer
              q = ev[:quality] || {}
              ev[:policy_revision] && [:native_jpeg_candidate, :semantic_colorized_native].include?(ev[:selected]) &&
                ev[:profile].to_s == 'exact' && ev[:native_jpeg] == true &&
                (ev[:selected] != :semantic_colorized_native || ev[:semantic_colorize_verified] == true) &&
                ev[:selected_sha256].is_a?(String) && ev[:selected_sha256].match?(/\A[0-9a-f]{64}\z/) &&
                ev[:selected_sha256] == tex[:sha256] && ev[:alpha_preserved] == true &&
                q[:compatible] == true && q[:alpha_preserved] == true &&
                q[:mean_squared_error] == 0.0 && q[:max_channel_error] == 0
            end
            unless verified
              textures_passed = false
              texture_failures << "decoded texture #{t_i} is JPEG without native JPEG provenance"
            end
          end
        end
      end

      unless textures_passed
        failures << "textures (#{texture_failures.join('; ')})"
      end

      passed = failures.empty?
      work_cursor&.flush('fidelity_validation')
      {
        passed: passed,
        profile: prof,
        failures: failures,
        domains: {
          counts: { exact: counts_match },
          materials: { exact: materials_exact },
          tags: { exact: tags_exact },
          definitions: { exact: definitions_exact },
          instances: { exact: instances_exact },
          semantics: { exact: semantics_exact },
          topology: { exact: topology_exact },
          visual_edges: { exact: visual_edges_exact },
          positions: {
            max_error_m: position_errors.summary[:max],
            passed: positions_passed,
            tolerance: pos_limit
          },
          normals: {
            max_angular_error_deg: normal_errors.summary[:max],
            passed: normals_passed,
            tolerance: norm_limit
          },
          uv: {
            max_error: uv_errors.summary[:max],
            passed: uv_passed,
            tolerance: uv_limit
          },
          transforms: {
            max_error: transform_errors.summary[:max],
            passed: transforms_passed,
            tolerance: transform_limit
          },
          areas: {
            max_error_m2: area_summary[:max],
            passed: areas_passed,
            tolerance: maximum_area_tolerance,
            basis: prof == :exact ? 'source_geometry' : 'source_area_metadata',
            source_metadata_max_delta_m2: source_area_metadata_errors.summary[:max],
            source_metadata_mismatch_count: source_area_metadata_mismatch_count
          },
          scenes: { exact: scenes_exact },
          clip_planes: { exact: clip_planes_exact },
          coverage: { unaccounted: unaccounted, passed: coverage_passed },
          textures: { passed: textures_passed, failures: texture_failures }
        }
      }
    end

    def self.validate_profile!(source:, decoded:, profile: :visual, texture_evidence: nil, base_path: nil, normalized_source: nil, checkpoint: nil)
      report = validate_profile(
        source: source,
        decoded: decoded,
        profile: profile,
        texture_evidence: texture_evidence,
        base_path: base_path,
        normalized_source: normalized_source,
        checkpoint: checkpoint
      )
      unless report[:passed]
        raise ProfileValidationError.new(
          "BOMC #{profile} profile validation failed: #{report[:failures].join(', ')}.",
          report: report
        )
      end
      report
    end

    def self.compare_materials_profile(source, decoded)
      return false unless source.length == decoded.length
      source.each_with_index.all? do |material, index|
        row = decoded[index]
        color = material[:color]
        has_src_tex = !material[:texture].nil?
        has_dec_tex = !row[:texture].nil?
        row &&
          material[:name].to_s == row[:name].to_s &&
          material[:display_name].to_s == row[:display_name].to_s &&
          [:r, :g, :b, :a].all? { |c| color[c].to_i == row.dig(:color, c).to_i } &&
          (material[:opacity].to_f - row[:opacity].to_f).abs <= (1.0 / 65_535.0 + 1.0e-12) &&
          material[:material_type].to_i == row[:material_type].to_i &&
          (material[:semantic_colorize_active] == true) == (row[:semantic_colorize_active] == true) &&
          (!material[:semantic_colorize_active] || (
            material[:colorize_type].to_s == row[:colorize_type].to_s &&
            [:h,:l,:s].all? { |key| material.dig(:colorize_deltas,key).to_f == row.dig(:colorize_deltas,key).to_f } &&
            material[:colorize_output_sha256].to_s == row[:colorize_output_sha256].to_s
          )) &&
          has_src_tex == has_dec_tex
      end
    end
    private_class_method :compare_materials_profile

    def self.compare_materials(source, decoded, textures)
      return false unless source.length == decoded.length
      source.each_with_index.all? do |material, index|
        row = decoded[index]
        source_texture = material.dig(:texture, :sha256)
        decoded_texture = row[:texture].nil? ? nil : textures.dig(row[:texture], :sha256)
        color = material[:color]
        row &&
          material[:name].to_s == row[:name].to_s &&
          material[:display_name].to_s == row[:display_name].to_s &&
          [:r, :g, :b, :a].all? { |channel| color[channel].to_i == row.dig(:color, channel).to_i } &&
          (material[:opacity].to_f - row[:opacity].to_f).abs <= (1.0 / 65_535.0 + 1.0e-12) &&
          material[:material_type].to_i == row[:material_type].to_i &&
          (material[:semantic_colorize_active] == true) == (row[:semantic_colorize_active] == true) &&
          (!material[:semantic_colorize_active] || (
            material[:colorize_type].to_s == row[:colorize_type].to_s &&
            [:h,:l,:s].all? { |key| material.dig(:colorize_deltas,key).to_f == row.dig(:colorize_deltas,key).to_f } &&
            material[:colorize_output_sha256].to_s == row[:colorize_output_sha256].to_s
          )) &&
          source_texture == decoded_texture
      end
    end
    private_class_method :compare_materials

    def self.compare_fallback(instances, decoded, textures)
      source = instances.each_with_index.each_with_object([]) do |(instance, index), records|
        records << instance[:fallback].merge(instance: index) if instance[:fallback]
      end
      return false unless source.length == decoded.length
      source.each_with_index.all? do |fallback, index|
        row = decoded[index]
        source_texture = fallback.dig(:texture, :sha256)
        decoded_texture = row[:texture].nil? ? nil : textures.dig(row[:texture], :sha256)
        position_error = 3.times.map { |axis| (Array(fallback[:position])[axis].to_f - row[:position][axis].to_f).abs }.max
        row && fallback[:instance] == row[:instance] && fallback[:kind].to_s == row[:kind].to_s &&
          position_error <= 1.0e-5 &&
          (fallback[:width_m].to_f - row[:width_m].to_f).abs <= 1.0e-5 &&
          (fallback[:height_m].to_f - row[:height_m].to_f).abs <= 1.0e-5 &&
          fallback[:text].to_s == row[:text].to_s && source_texture == decoded_texture
      end
    end
    private_class_method :compare_fallback

    def self.normalize_surface(value)
      normalized = value.to_s.downcase.tr(' ', '_')
      BOMC::SURFACE_TYPES.key?(normalized) ? normalized : 'unknown'
    end
    private_class_method :normalize_surface

    def self.normalize_role(value)
      normalized = value.to_s.downcase.tr(' ', '_')
      BOMC::SEMANTIC_ROLES.key?(normalized) && !normalized.empty? ? normalized : 'unknown'
    end
    private_class_method :normalize_role

    def self.optional_string(value)
      value.nil? || value.to_s.empty? ? nil : value.to_s
    end
    private_class_method :optional_string

    def self.each_point_error(source, decoded, work_cursor = nil)
      unless source.length == decoded.length
        yield Float::INFINITY
        return
      end
      index = 0
      while index < source.length
        work_cursor&.step('fidelity_validation')
        dx = source[index].to_f - decoded[index].to_f
        dy = source[index + 1].to_f - decoded[index + 1].to_f
        dz = source[index + 2].to_f - decoded[index + 2].to_f
        yield Math.sqrt(dx * dx + dy * dy + dz * dz)
        index += 3
      end
    end
    private_class_method :each_point_error

    def self.each_pair_error(source, decoded, work_cursor = nil)
      unless source.length == decoded.length
        yield Float::INFINITY
        return
      end
      index = 0
      while index < source.length
        work_cursor&.step('fidelity_validation')
        du = source[index].to_f - decoded[index].to_f
        dv = source[index + 1].to_f - decoded[index + 1].to_f
        yield Math.sqrt(du * du + dv * dv)
        index += 2
      end
    end
    private_class_method :each_pair_error

    def self.nested_scalar_count(value)
      return 0 if value.nil?
      return 1 unless value.is_a?(Array)
      value.inject(0) { |sum, child| sum + nested_scalar_count(child) }
    end
    private_class_method :nested_scalar_count

    def self.angular_error(left, right)
      return Float::INFINITY unless [left, right].all? do |vector|
        vector.is_a?(Array) && vector.length == 3 && vector.all? { |value| value.is_a?(Numeric) && value.finite? }
      end
      # acos(dot(n,n)) can invent a ~1e-6 degree error from roundoff even
      # when FLOAT64 preserved all three components without any change.
      return 0.0 if left == right

      left_length = Math.sqrt(left.map { |value| value.to_f * value.to_f }.inject(0.0, :+))
      right_length = Math.sqrt(right.map { |value| value.to_f * value.to_f }.inject(0.0, :+))
      return 0.0 if left_length.zero? && right_length.zero?
      return 180.0 if left_length.zero? || right_length.zero?
      dot = 3.times.map { |axis| (left[axis].to_f / left_length) * (right[axis].to_f / right_length) }.inject(0.0, :+)
      Math.acos([[dot, -1.0].max, 1.0].min) * 180.0 / Math::PI
    end
    private_class_method :angular_error

    # Independent area reference from the input geometry; do not call the
    # decoder or copy its computed output into the expected value.
    def self.geometry_face_area(positions, face, work_cursor = nil)
      triangles = Array(face[:triangles])
      if triangles.length >= 3
        return triangles.each_slice(3).inject(0.0) do |total, indices|
          work_cursor&.step('fidelity_validation')
          a, b, c = indices.map { |index| positions[index * 3, 3] }
          u = 3.times.map { |axis| b[axis] - a[axis] }
          v = 3.times.map { |axis| c[axis] - a[axis] }
          cross = [u[1]*v[2] - u[2]*v[1], u[2]*v[0] - u[0]*v[2], u[0]*v[1] - u[1]*v[0]]
          total + 0.5 * Math.sqrt(cross.inject(0.0) { |sum, value| sum + value * value })
        end
      end
      loop_area = lambda do |indices|
        return 0.0 if indices.length < 3
        vector = [0.0, 0.0, 0.0]
        indices.each_with_index do |index, cursor|
          a = positions[index * 3, 3]
          b = positions[indices[(cursor + 1) % indices.length] * 3, 3]
          3.times do |axis|
            j, k = (axis + 1) % 3, (axis + 2) % 3
            vector[axis] += (a[j] - b[j]) * (a[k] + b[k])
          end
        end
        0.5 * Math.sqrt(vector.inject(0.0) { |sum, value| sum + value * value })
      end
      holes_area = Array(face[:holes]).inject(0.0) { |sum, hole| sum + loop_area.call(hole) }
      [loop_area.call(face[:outer]) - holes_area, 0.0].max
    end
    private_class_method :geometry_face_area

    def self.flatten_uv(uv)
      return [] unless uv.is_a?(Hash)
      [:front_outer, :front_holes, :back_outer, :back_holes].map do |key|
        Array(uv[key]).flatten
      end.flatten.map(&:to_f)
    end
    private_class_method :flatten_uv
  end
end
