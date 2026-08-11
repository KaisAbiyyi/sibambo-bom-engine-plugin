# frozen_string_literal: true

require 'digest'

module BOMEngine
  module CleanAnalysis
    # Converts the private extraction snapshot into a small, analysis-oriented
    # document. Polygon surfaces are authoritative; triangulation is never
    # emitted by this compiler.
    class Compiler
      FORMAT_IDENTIFIER = 'bom_engine_clean_v1'.freeze
      FORMAT_VERSION = '1.0.0'.freeze
      POSITION_TOLERANCE_M = 1.0e-6
      SERIALIZATION_DECIMAL_PLACES = 9
      NORMAL_TOLERANCE = 1.0e-6
      VERTICAL_NORMAL_Z_MAX = 0.15
      HORIZONTAL_NORMAL_Z_MIN = 0.95

      SURFACE_ROLES = {
        'wall' => 'wall',
        'exterior_wall' => 'wall',
        'interior_wall' => 'wall',
        'floor' => 'floor',
        'ceiling' => 'ceiling',
        'roof' => 'roof',
        'opening' => 'opening'
      }.freeze
      COMPONENT_ROLES = {
        'door' => 'door',
        'window' => 'window',
        'opening' => 'opening',
        'furniture' => 'furniture',
        'fixture' => 'fixture'
      }.freeze
      ENTOURAGE_PATTERN = /(?:\bsree\b|\b(?:human|person|people|entourage|man|woman)\b)/i.freeze
      DECORATION_PATTERN = /\b(?:plant|tree|vegetation|decoration|decorative|ornament|presentation)\b/i.freeze

      class << self
        def compile(snapshot_document, progress: nil, profiler: nil, visual_edges: [], debug: false)
          new(
            snapshot_document,
            progress: progress,
            profiler: profiler,
            visual_edges: visual_edges,
            debug: debug
          ).compile
        end
      end

      def initialize(snapshot_document, progress: nil, profiler: nil, visual_edges: [], debug: false)
        unless snapshot_document.is_a?(BOMEngine::SemanticV2::Snapshot::Document)
          raise ArgumentError, 'clean analysis compiler requires a neutral extraction snapshot'
        end

        @snapshot = snapshot_document
        @progress = progress
        @profiler = profiler
        @debug = debug == true
        @visual_edges = Array(visual_edges).map { |edge| normalized_visual_edge(edge) }
        @visual_edges_by_definition = @visual_edges.group_by { |edge| edge.fetch(:definition_uuid) }
        @coverage = CoverageLedger.new(snapshot_document.primitives, @visual_edges)
        @surface_primitive_keys = {}
        @definitions = snapshot_document.definitions.each_with_object({}) do |definition, index|
          checkpoint('Compiling definition index')
          index[definition.source_uuid] = definition
        end
        @primitives = snapshot_document.primitives.each_with_object({}) do |primitive, index|
          checkpoint('Compiling primitive index')
          index[primitive.key] = primitive
        end
        @material_ids = snapshot_document.materials.each_with_object({}) do |material, index|
          checkpoint('Compiling material index')
          index[material.source_uuid] = stable_id('mat', material.source_uuid)
        end
        @labels = Hash.new { |hash, key| hash[key] = [] }
        snapshot_document.evidence.each do |item|
          checkpoint('Compiling semantic evidence')
          next unless item.is_a?(BOMEngine::SemanticV2::Snapshot::LabelEvidence)

          @labels[[item.target_kind, item.target_key]] << item
        end
        @definition_usage = Hash.new(0)
        snapshot_document.occurrences.each do |occurrence|
          @definition_usage[occurrence.definition_uuid] += 1 unless occurrence.uuid_path.empty?
        end
        @emitted_instance_ids = {}
        @excluded_primitive_count = 0
        @definition_fallback_geometry = []
      end

      def compile
        candidates = []
        components = []
        instances = []
        retained_definition_categories = Hash.new { |hash, key| hash[key] = [] }
        excluded_objects = []
        excluded_paths = []
        visual_edges = []

        @snapshot.occurrences.sort_by { |occurrence| [occurrence.uuid_path.length, occurrence.uuid_path] }.each do |occurrence|
          checkpoint('Compiling model occurrences')
          if path_below_any?(occurrence.uuid_path, excluded_paths)
            excluded_definition = @definitions.fetch(occurrence.definition_uuid)
            @excluded_primitive_count += excluded_definition.primitive_keys.length
            mark_definition_coverage(
              excluded_definition,
              'explicitly_excluded',
              reason: 'ancestor_analysis_irrelevant',
              occurrence_path: occurrence.uuid_path
            )
            next
          end

          definition = @definitions.fetch(occurrence.definition_uuid)
          label = primary_label('occurrence', occurrence.uuid_path)
          category = occurrence_category(occurrence, definition, label)
          if %w[entourage decoration].include?(category)
            profile_occurrence(occurrence, definition, category, 'excluded')
            excluded_paths << occurrence.uuid_path
            @excluded_primitive_count += definition.primitive_keys.length
            mark_definition_coverage(
              definition,
              'explicitly_excluded',
              reason: 'analysis_irrelevant',
              occurrence_path: occurrence.uuid_path
            )
            excluded_objects << excluded_object(occurrence, label, category)
          elsif retained_occurrence?(occurrence, definition, category)
            profile_occurrence(occurrence, definition, category, 'referenced')
            instance = shared_instance(occurrence, definition, label, category)
            retained_definition_categories[definition.source_uuid] << instance.fetch('retention')
            instances << instance
            @profiler.record_instance(instance, occurrence) if @profiler
            @emitted_instance_ids[path_key(occurrence.uuid_path)] = instance.fetch('id')
          elsif surface_category?(category) || category == 'container'
            profile_occurrence(occurrence, definition, category, 'expanded')
            definition.primitive_keys.each do |primitive_key|
              checkpoint('Compiling polygon candidates')
              candidates << surface_candidate(
                occurrence,
                @primitives.fetch(primitive_key),
                occurrence_category: category,
                occurrence_label: label
              )
            end
            @visual_edges_by_definition.fetch(definition.source_uuid, []).each do |edge|
              visual_edges << expanded_visual_edge(edge, occurrence)
              @coverage.mark(
                edge_key(edge),
                'visual_retained',
                reason: 'standalone_visual_edge',
                occurrence_ancestry: occurrence.uuid_path
              )
            end
          else
            raise "unhandled eligible CleanV1 occurrence category: #{category}"
          end
        end

        contextualize_geometry_hints!(candidates)
        compiled_surfaces = merge_candidates(candidates)
        surfaces, invalid_surfaces = compiled_surfaces.partition do |surface|
          checkpoint('Validating compiled surfaces')
          SurfaceValidator.validate(surface).empty?
        end
        surfaces.sort_by! { |surface| surface.fetch('id') }
        fallback_geometry = invalid_surfaces.map do |surface|
          checkpoint('Recording unresolved surfaces')
          unresolved_surface(surface)
        end.sort_by { |item| item.fetch('id') }
        surfaces.each { |surface| mark_surface_coverage(surface, 'analytical', 'architectural_surface') }
        invalid_surfaces.each { |surface| mark_surface_coverage(surface, 'fallback', 'invalid_surface') }
        components.sort_by! { |component| component.fetch('id') }
        instances.sort_by! { |instance| instance.fetch('id') }
        retained_definitions = retained_definition_categories.keys.sort.map do |definition_uuid|
          checkpoint('Compiling shared definition geometry')
          compiled = shared_definition(
            @definitions.fetch(definition_uuid),
            retained_definition_categories.fetch(definition_uuid)
          )
          @profiler.record_definition(compiled, definition_uuid) if @profiler
          compiled
        end
        fallback_geometry.concat(@definition_fallback_geometry)
        fallback_geometry.sort_by! { |item| item.fetch('id') }
        visual_edges.sort_by! { |edge| edge.fetch('id') }
        excluded_objects.sort_by! { |item| item.fetch('id') }
        referenced_material_ids = material_references(
          surfaces,
          retained_definitions,
          instances,
          components,
          fallback_geometry,
          visual_edges
        )
        materials = @snapshot.materials.sort_by(&:source_uuid).select do |material|
          referenced_material_ids.key?(@material_ids.fetch(material.source_uuid))
        end.map do |material|
          checkpoint('Compiling material appearance')
          compiled_material(material)
        end
        top_level_vertices = surfaces.inject(0) do |total, surface|
          total + surface.fetch('outer').length + surface.fetch('holes').inject(0) { |sum, loop| sum + loop.length }
        end
        definition_vertex_references = retained_definitions.inject(0) do |definition_total, definition|
          definition_total + definition.dig('geometry', 'surfaces').inject(0) do |surface_total, surface|
            surface_total + surface.fetch('outer').length +
              surface.fetch('holes').inject(0) { |sum, loop| sum + loop.length }
          end
        end
        definition_vertices = retained_definitions.inject(0) do |sum, definition|
          sum + definition.dig('geometry', 'vertices').length
        end
        retained_definition_fragments = retained_definition_categories.keys.inject(0) do |sum, definition_uuid|
          sum + @definitions.fetch(definition_uuid).primitive_keys.length
        end

        {
          'format' => {
            'identifier' => FORMAT_IDENTIFIER,
            'version' => FORMAT_VERSION
          },
          'units' => 'm',
          'coordinate_system' => {
            'handedness' => 'right',
            'up_axis' => '+Z',
            'true_north_xy' => @snapshot.model_context.true_north_xy.dup,
            'instance_transform_space' => 'world'
          },
          'model' => {
            'bounds' => bounds(surfaces, components, instances)
          },
          'materials' => materials,
          'surfaces' => surfaces,
          'definitions' => retained_definitions,
          'instances' => instances,
          'components' => components,
          'visual_edges' => visual_edges,
          'excluded_objects' => excluded_objects,
          'fallback_geometry' => fallback_geometry,
          'diagnostics' => {
            'excluded' => {
              'analysis_irrelevant_objects' => excluded_objects.length,
              'source_polygon_fragments' => @excluded_primitive_count
            },
            'counts' => {
              'source_polygon_fragments' => candidates.length + retained_definition_fragments,
              'architectural_surface_count' => surfaces.length,
              'retained_definition_count' => retained_definitions.length,
              'retained_definition_polygon_count' => retained_definitions.inject(0) do |sum, definition|
                sum + definition.dig('geometry', 'surfaces').length
              end,
              'material_count' => materials.length,
              'standalone_edge_count' => visual_edges.length + retained_definitions.inject(0) do |sum, definition|
                sum + definition.dig('geometry', 'edges').length
              end,
              'instance_count' => instances.length,
              'component_count' => components.length,
              'excluded_object_count' => excluded_objects.length,
              'fallback_geometry_count' => fallback_geometry.length,
              'unresolved_fragment_count' => fallback_geometry.inject(0) do |sum, item|
                sum + item.fetch('source_count')
              end,
              'omitted_component_source_fragments' => components.inject(0) do |sum, component|
                sum + component.fetch('geometry').fetch('source_count')
              end,
              'raw_vertices_serialized' => top_level_vertices + definition_vertices,
              'polygon_vertex_references' => top_level_vertices + definition_vertex_references,
              'raw_triangle_indices_serialized' => 0
            },
            'coverage' => @coverage.counts,
            'materials' => {
              'source' => @snapshot.materials.length,
              'referenced' => referenced_material_ids.length,
              'emitted' => materials.length,
              'unused_emitted' => materials.count do |material|
                !referenced_material_ids.key?(material.fetch('id'))
              end
            },
            'topology' => topology_diagnostics(surfaces, retained_definitions, visual_edges),
            'definitions' => definition_diagnostics(retained_definitions),
            'area_m2' => {
              'source' => clean_number(candidates.inject(0.0) { |sum, item| sum + item.fetch(:area_m2) }),
              'resolved' => clean_number(surfaces.inject(0.0) { |sum, item| sum + item.fetch('area_m2') }),
              'unresolved' => clean_number(fallback_geometry.inject(0.0) { |sum, item| sum + item.fetch('area_m2') })
            }
          }.tap do |diagnostics|
            diagnostics['coverage_ledger'] = @coverage.entries if @debug
          end
        }
      end

      private

      def primary_label(kind, key, occurrence_path = nil)
        values = scoped_labels(kind, key, occurrence_path)
        values.find(&:primary) || values.first
      end

      def role_for(kind, key, occurrence_path = nil)
        values = scoped_labels(kind, key, occurrence_path)
        evidence = values.find { |item| !item.role.nil? && !item.role.to_s.empty? }
        evidence && evidence.role
      end

      def scoped_labels(kind, key, occurrence_path)
        values = @labels.fetch([kind, key], [])
        return values if kind != 'primitive' || occurrence_path.nil?

        exact = values.select { |item| item.target_occurrence_uuid_path == occurrence_path }
        return exact unless exact.empty?

        values.select { |item| item.target_occurrence_uuid_path.nil? }
      end

      def occurrence_category(occurrence, definition, label)
        role = role_for('occurrence', occurrence.uuid_path)
        return SURFACE_ROLES.fetch(role) if SURFACE_ROLES.key?(role)
        return COMPONENT_ROLES.fetch(role) if COMPONENT_ROLES.key?(role)

        text = label && label.label.to_s
        return 'entourage' if text && ENTOURAGE_PATTERN.match?(text)
        return 'decoration' if text && DECORATION_PATTERN.match?(text)
        return 'container' if occurrence.uuid_path.empty? || %w[model group].include?(definition.kind)
        return 'container' if definition.primitive_keys.any? do |primitive_key|
          SURFACE_ROLES.key?(role_for('primitive', primitive_key, occurrence.uuid_path))
        end

        'unknown'
      end

      def surface_category?(category)
        %w[wall floor ceiling roof opening].include?(category)
      end

      def path_below_any?(path, prefixes)
        prefixes.any? do |prefix|
          path.length > prefix.length && path.first(prefix.length) == prefix
        end
      end

      def excluded_object(occurrence, label, category)
        {
          'id' => stable_id('excluded', occurrence.uuid_path),
          'name' => display_name(label, category),
          'category' => category,
          'reason' => 'analysis_irrelevant'
        }
      end

      def compact_component(occurrence, definition, label, category)
        item = {
          'id' => stable_id('component', occurrence.uuid_path),
          'name' => display_name(label, category),
          'category' => category,
          'transform' => occurrence.transform.map { |value| clean_number(value) },
          'geometry' => {
            'status' => 'omitted',
            'reason' => 'clean_analysis_profile',
            'source_count' => definition.primitive_keys.length
          }
        }
        assign_material_id!(item, 'material_id', occurrence.material_uuid)
        item
      end

      def retained_occurrence?(occurrence, definition, category)
        return false if occurrence.uuid_path.empty?
        return true if @definition_usage[occurrence.definition_uuid] > 1
        return true unless surface_category?(category) || category == 'container'
        return true unless @visual_edges_by_definition.fetch(definition.source_uuid, []).empty?

        category == 'container' && definition.primitive_keys.empty?
      end

      def shared_instance(occurrence, definition, label, category)
        overrides = definition.primitive_keys.each_with_object([]) do |primitive_key, values|
          override = shared_surface_override(occurrence, @primitives.fetch(primitive_key))
          values << override if override
        end
        retention = if surface_category?(category) || !overrides.empty?
                      'analysis_boundary'
                    else
                      'visual_architectural_detail'
                    end
        item = {
          'id' => stable_id('instance', occurrence.uuid_path),
          'definition_id' => stable_id('definition', definition.source_uuid),
          'name' => display_name(label, category),
          'category' => category,
          'retention' => retention,
          'transform' => occurrence.transform.map { |value| clean_number(value) },
          'transform_kind' => transform_kind(occurrence.transform)
        }
        assign_material_id!(item, 'material_id', occurrence.material_uuid)
        parent_id = @emitted_instance_ids[path_key(occurrence.uuid_path[0...-1])]
        item['parent_instance_id'] = parent_id if parent_id
        if item.fetch('transform_kind') == 'non_uniform_scale'
          item['normal_transform'] = 'inverse_transpose_required'
        end
        item['surface_classification_overrides'] = overrides unless overrides.empty?
        item
      end

      def shared_surface_override(occurrence, primitive)
        label = primary_label('primitive', primitive.key, occurrence.uuid_path)
        role = SURFACE_ROLES[role_for('primitive', primitive.key, occurrence.uuid_path)]
        return nil if label.nil? && role.nil?

        classification = {
          'method' => role ? (label && label.explicit ? 'explicit_label' : 'semantic_role') : 'label_hint',
          'label' => label && label.label,
          'source' => label && label.source
        }.reject { |_key, value| value.nil? }
        {
          'surface_id' => stable_id('definition-surface', primitive.key),
          'type' => role || geometric_surface_type(primitive.normal),
          'classification' => compact_classification(classification)
        }
      end

      def shared_definition(definition, categories)
        compiled_surfaces = definition.primitive_keys.sort.map do |primitive_key|
          checkpoint('Retaining definition-local polygons')
          definition_surface(@primitives.fetch(primitive_key))
        end
        surfaces, invalid_surfaces = compiled_surfaces.partition do |surface|
          SurfaceValidator.validate(surface).empty?
        end
        definition_id = stable_id('definition', definition.source_uuid)
        invalid_surfaces.each do |surface|
          @definition_fallback_geometry << unresolved_surface(
            surface,
            definition_id: definition_id
          )
        end
        surfaces.each { |surface| mark_surface_coverage(surface, 'visual_retained', 'shared_definition_polygon') }
        invalid_surfaces.each { |surface| mark_surface_coverage(surface, 'fallback', 'invalid_definition_polygon') }
        definition_edges = @visual_edges_by_definition.fetch(definition.source_uuid, []).sort_by do |edge|
          edge.fetch(:source_uuid)
        end
        vertices, indexed_surfaces, indexed_edges = pool_definition_vertices(surfaces, definition_edges)
        definition_edges.each do |edge|
          @coverage.mark(edge_key(edge), 'visual_retained', reason: 'shared_definition_edge')
        end
        retention = categories.include?('analysis_boundary') ?
          'analysis_boundary' : 'visual_architectural_detail'
        if retention == 'visual_architectural_detail'
          indexed_surfaces = indexed_surfaces.map do |surface|
            compact = {
              'type' => surface.fetch('type'),
              'outer' => surface.fetch('outer'),
              'holes' => surface.fetch('holes')
            }
            copy_material_ids!(compact, surface, %w[front_material_id back_material_id])
            compact
          end
        end
        {
          'id' => definition_id,
          'kind' => definition.kind,
          'retention' => retention,
          'geometry' => {
            'coordinate_space' => 'definition_local',
            'source_count' => definition.primitive_keys.length,
            'edge_source_count' => definition_edges.length,
            'vertices' => vertices,
            'surfaces' => indexed_surfaces,
            'edges' => indexed_edges
          }
        }
      end

      def pool_definition_vertices(surfaces, edges = [])
        vertices = []
        indices_by_point = {}
        indexed_surfaces = surfaces.map do |surface|
          surface.merge(
            'outer' => pooled_loop(surface.fetch('outer'), vertices, indices_by_point),
            'holes' => surface.fetch('holes').map do |loop|
              pooled_loop(loop, vertices, indices_by_point)
            end
          )
        end
        indexed_edges = edges.map do |edge|
          edge.fetch(:vertices).map do |point|
            pooled_point(point, vertices, indices_by_point)
          end
        end
        [vertices, indexed_surfaces, indexed_edges]
      end

      def pooled_loop(points, vertices, indices_by_point)
        points.map do |point|
          pooled_point(point, vertices, indices_by_point)
        end
      end

      def pooled_point(point, vertices, indices_by_point)
        indices_by_point[point] ||= begin
          vertices << point
          vertices.length - 1
        end
      end

      def definition_surface(primitive)
        outer_loop = primitive.loops.find { |loop| loop.kind == 'outer' }
        hole_loops = primitive.loops.select { |loop| loop.kind == 'hole' }
        normal = normalize(primitive.normal)
        plane_origin = outer_loop.vertices.first
        outer = normalize_loop_start(
          project_loop_to_plane(outer_loop.vertices, normal, plane_origin)
        ).map { |point| clean_point(point) }
        holes = hole_loops.map do |loop|
          normalize_loop_start(
            project_loop_to_plane(loop.vertices, normal, plane_origin)
          ).map { |point| clean_point(point) }
        end.sort_by { |loop| loop_sort_key(loop) }
        surface = {
          'id' => stable_id('definition-surface', primitive.key),
          'type' => 'polygon',
          'outer' => outer,
          'holes' => holes,
          'normal' => clean_point(normal),
          'area_m2' => clean_number(loop_area(outer) - holes.inject(0.0) { |sum, hole| sum + loop_area(hole) }),
          'source_count' => 1
        }.merge('classification_hint' => geometric_surface_type(primitive.normal))
        assign_material_id!(surface, 'front_material_id', primitive.front_material_uuid)
        assign_material_id!(surface, 'back_material_id', primitive.back_material_uuid)
        @surface_primitive_keys[surface.fetch('id')] = [primitive.key]
        surface
      end

      def unresolved_surface(surface, definition_id: nil)
        item = {
          'id' => stable_id('unresolved', surface.fetch('id')),
          'status' => 'unresolved',
          'reason' => 'invalid_surface',
          'source_count' => surface.fetch('source_count'),
          'area_m2' => surface.fetch('area_m2'),
          'outer' => surface.fetch('outer'),
          'holes' => surface.fetch('holes'),
          'validation_issues' => SurfaceValidator.validate(surface)
        }
        item['definition_id'] = definition_id if definition_id
        copy_material_ids!(
          item,
          surface,
          %w[front_material_id back_material_id inherited_material_id]
        )
        item
      end

      def project_loop_to_plane(points, normal, origin)
        points.map do |point|
          distance = dot(normal, subtract(point, origin))
          3.times.map { |axis| point[axis] - normal[axis] * distance }
        end
      end

      def display_name(label, category)
        value = label && label.label.to_s.strip
        value.nil? || value.empty? ? category.capitalize : value
      end

      def surface_candidate(occurrence, primitive, occurrence_category:, occurrence_label:)
        primitive_label = primary_label('primitive', primitive.key, occurrence.uuid_path)
        explicit_role = SURFACE_ROLES[role_for('primitive', primitive.key, occurrence.uuid_path)]
        inherited_role = surface_category?(occurrence_category) ? occurrence_category : nil
        type = explicit_role || inherited_role || geometric_surface_type(primitive.normal)
        label = primitive_label || (inherited_role && occurrence_label)
        world_loops = primitive.loops.map do |loop|
          [loop.kind, loop.vertices.map { |point| transform_point(occurrence.transform, point) }]
        end
        outer = world_loops.find { |kind, _points| kind == 'outer' }.last
        holes = world_loops.select { |kind, _points| kind == 'hole' }.map(&:last)
        normal = transform_normal(occurrence.transform, primitive.normal)
        semantic_role = explicit_role || inherited_role
        classification_method = if semantic_role && label
                                  label.explicit ? 'explicit_label' : 'semantic_label'
                                elsif semantic_role
                                  'semantic_role'
                                elsif label
                                  'label_hint'
                                else
                                  'geometry_hint'
                                end

        {
          occurrence_path: occurrence.uuid_path,
          definition_uuid: occurrence.definition_uuid,
          primitive_key: primitive.key,
          adjacent_keys: primitive.loops.flat_map(&:adjacent_primitive_keys).uniq,
          type: type,
          outer: outer,
          holes: holes,
          normal: normal,
          area_m2: loop_area(outer) - holes.inject(0.0) { |sum, hole| sum + loop_area(hole) },
          front_material_uuid: primitive.front_material_uuid,
          back_material_uuid: primitive.back_material_uuid,
          inherited_material_uuid: occurrence.material_uuid,
          source_count: 1,
          classification: {
            'method' => classification_method,
            'label' => label && label.label,
            'source' => label && label.source
          }.reject { |_key, value| value.nil? }
        }
      end

      def contextualize_geometry_hints!(candidates)
        geometric = candidates.select do |candidate|
          %w[geometry_hint label_hint].include?(
            candidate.fetch(:classification).fetch('method')
          )
        end
        return if geometric.empty?

        all_points = candidates.flat_map { |candidate| candidate.fetch(:outer) }
        minimum_z = all_points.map { |point| point[2] }.min
        maximum_z = all_points.map { |point| point[2] }.max
        model_height = maximum_z.to_f - minimum_z.to_f
        horizontal = geometric.select do |candidate|
          candidate.fetch(:normal)[2].abs >= HORIZONTAL_NORMAL_Z_MIN
        end
        primary_floor_z = horizontal.map { |candidate| mean_z(candidate.fetch(:outer)) }.min
        primary_ceiling_z = horizontal.map { |candidate| mean_z(candidate.fetch(:outer)) }.max

        geometric.each do |candidate|
          type = candidate.fetch(:type)
          reason = nil
          case type
          when 'wall'
            height = z_span(candidate.fetch(:outer))
            fill_ratio = planar_fill_ratio(candidate)
            if model_height > POSITION_TOLERANCE_M &&
               height / model_height >= 0.5 && fill_ratio >= 0.5
              reason = 'full_height_vertical_region'
            else
              candidate[:type] = 'other_architectural_surface'
              reason = 'thin_or_fragmentary_vertical_region'
            end
          when 'floor', 'ceiling'
            elevation = mean_z(candidate.fetch(:outer))
            if primary_floor_z && primary_ceiling_z &&
               (primary_ceiling_z - primary_floor_z).abs <= POSITION_TOLERANCE_M
              candidate[:type] = candidate.fetch(:normal)[2].negative? ? 'ceiling' : 'floor'
              reason = 'single_horizontal_level_normal_hint'
            elsif primary_floor_z && (elevation - primary_floor_z).abs <= POSITION_TOLERANCE_M
              candidate[:type] = 'floor'
              reason = 'primary_lowest_horizontal_region'
            elsif primary_ceiling_z && (elevation - primary_ceiling_z).abs <= POSITION_TOLERANCE_M
              candidate[:type] = 'ceiling'
              reason = 'primary_highest_horizontal_region'
            else
              candidate[:type] = 'other_architectural_surface'
              reason = 'intermediate_horizontal_region'
            end
          else
            reason = 'sloped_geometry_region'
          end
          candidate.fetch(:classification)['reason'] = reason
        end
      end

      def z_span(points)
        values = points.map { |point| point[2] }
        values.max.to_f - values.min.to_f
      end

      def mean_z(points)
        points.inject(0.0) { |sum, point| sum + point[2].to_f } / points.length
      end

      def planar_fill_ratio(candidate)
        normal = candidate.fetch(:normal)
        omitted_axis = normal.each_index.max_by { |index| normal[index].abs }
        axes = [0, 1, 2] - [omitted_axis]
        points = candidate.fetch(:outer)
        bounding_area = axes.inject(1.0) do |product, axis|
          values = points.map { |point| point[axis] }
          product * (values.max.to_f - values.min.to_f)
        end
        return 0.0 if bounding_area <= POSITION_TOLERANCE_M**2

        candidate.fetch(:area_m2) / bounding_area
      end

      def geometric_surface_type(normal)
        z = normalize(normal)[2]
        return 'wall' if z.abs <= VERTICAL_NORMAL_Z_MAX
        return 'floor' if z >= HORIZONTAL_NORMAL_Z_MIN
        return 'ceiling' if z <= -HORIZONTAL_NORMAL_Z_MIN

        'roof'
      end

      def merge_candidates(candidates)
        candidates.group_by { |candidate| merge_group_key(candidate) }.values.flat_map do |group|
          checkpoint('Merging coplanar surfaces')
          connected_components(group).flat_map do |component|
            checkpoint('Merging connected surface regions')
            merged = merge_component(component)
            merged.nil? ? component.map { |candidate| surface_hash(candidate) } : [surface_hash(merged)]
          end
        end
      end

      def merge_group_key(candidate)
        normal = candidate.fetch(:normal)
        plane = dot(normal, candidate.fetch(:outer).first)
        [
          candidate.fetch(:occurrence_path),
          candidate.fetch(:type),
          candidate.fetch(:front_material_uuid),
          candidate.fetch(:back_material_uuid),
          candidate.fetch(:inherited_material_uuid),
          candidate.fetch(:classification),
          normal.map { |value| quantize(value, NORMAL_TOLERANCE) },
          quantize(plane, POSITION_TOLERANCE_M)
        ]
      end

      def connected_components(group)
        by_key = group.each_with_object({}) { |candidate, index| index[candidate.fetch(:primitive_key)] = candidate }
        remaining = group.dup
        components = []
        until remaining.empty?
          seed = remaining.shift
          component = []
          pending = [seed]
          until pending.empty?
            current = pending.shift
            next if component.include?(current)

            component << current
            current.fetch(:adjacent_keys).each do |key|
              neighbor = by_key[key]
              if neighbor && !component.include?(neighbor)
                remaining.delete(neighbor)
                pending << neighbor
              end
            end
          end
          components << component
        end
        components
      end

      def merge_component(component)
        return component.first if component.length == 1

        boundary_loops = union_boundary_loops(component.map { |candidate| candidate.fetch(:outer) })
        return nil if boundary_loops.nil? || boundary_loops.empty?

        ordered = boundary_loops.sort_by { |loop| [-loop_area(loop), loop_sort_key(loop)] }
        first = component.first
        return nil unless ordered.drop(1).all? do |loop|
          SurfaceValidator.loop_inside?(loop, ordered.first, first.fetch(:normal))
        end

        first.merge(
          primitive_key: component.map { |item| item.fetch(:primitive_key) }.sort,
          adjacent_keys: [],
          outer: ordered.first,
          holes: ordered.drop(1) + component.flat_map { |item| item.fetch(:holes) },
          area_m2: component.inject(0.0) { |sum, item| sum + item.fetch(:area_m2) },
          source_count: component.inject(0) { |sum, item| sum + item.fetch(:source_count) }
        )
      end

      def union_boundary_loops(loops)
        all_points = loops.flatten(1)
        segments = {}
        loops.each do |loop|
          loop.each_with_index do |start_point, index|
            end_point = loop[(index + 1) % loop.length]
            split_segment(start_point, end_point, all_points).each_cons(2) do |split_start, split_end|
              start_key = point_key(split_start)
              end_key = point_key(split_end)
              next if start_key == end_key

              undirected = [start_key, end_key].sort
              entry = segments[undirected]
              if entry
                return nil unless entry.fetch(:start_key) == end_key && entry.fetch(:end_key) == start_key

                segments.delete(undirected)
              else
                segments[undirected] = {
                  start_key: start_key,
                  end_key: end_key,
                  start_point: split_start,
                  end_point: split_end
                }
              end
            end
          end
        end

        outgoing = Hash.new { |hash, key| hash[key] = [] }
        segments.values.each { |segment| outgoing[segment.fetch(:start_key)] << segment }
        return nil if outgoing.values.any? { |values| values.length != 1 }

        remaining = segments.values.dup
        result = []
        until remaining.empty?
          first = remaining.min_by { |segment| segment.fetch(:start_key) }
          loop = []
          current = first
          start_key = first.fetch(:start_key)
          loop_guard = 0
          loop do
            loop << current.fetch(:start_point)
            remaining.delete(current)
            next_key = current.fetch(:end_key)
            break if next_key == start_key

            current = outgoing.fetch(next_key, []).first
            return nil if current.nil? || !remaining.include?(current)

            loop_guard += 1
            return nil if loop_guard > segments.length
          end
          simplified = simplify_loop(loop)
          return nil if simplified.length < 3

          result << normalize_loop_start(simplified)
        end
        result
      end

      def split_segment(start_point, end_point, candidates)
        direction = subtract(end_point, start_point)
        length_squared = dot(direction, direction)
        return [start_point, end_point] if length_squared <= POSITION_TOLERANCE_M**2

        points = candidates.each_with_object({}) do |point, index|
          offset = subtract(point, start_point)
          next if vector_length(cross(direction, offset)) > POSITION_TOLERANCE_M * Math.sqrt(length_squared)

          parameter = dot(offset, direction) / length_squared
          next if parameter < -POSITION_TOLERANCE_M || parameter > 1.0 + POSITION_TOLERANCE_M

          index[point_key(point)] = [parameter, point]
        end
        points.values.sort_by(&:first).map(&:last)
      end

      def simplify_loop(loop)
        points = loop.dup
        changed = true
        while changed && points.length > 3
          changed = false
          points.length.times do |index|
            previous = points[(index - 1) % points.length]
            current = points[index]
            following = points[(index + 1) % points.length]
            first = subtract(current, previous)
            second = subtract(following, current)
            next unless vector_length(cross(first, second)) <= POSITION_TOLERANCE_M && dot(first, second) > 0.0

            points.delete_at(index)
            changed = true
            break
          end
        end
        points
      end

      def normalize_loop_start(loop)
        start_index = loop.each_index.min_by { |index| point_key(loop[index]) }
        loop.rotate(start_index)
      end

      def surface_hash(candidate)
        primitive_keys = candidate.fetch(:primitive_key)
        primitive_keys = [primitive_keys] unless primitive_keys.first.is_a?(Array)
        outer = normalize_loop_start(candidate.fetch(:outer)).map { |point| clean_point(point) }
        holes = candidate.fetch(:holes).map do |hole|
          normalize_loop_start(hole).map { |point| clean_point(point) }
        end.sort_by { |hole| loop_sort_key(hole) }
        surface_id = stable_id(
            'surface',
            candidate.fetch(:occurrence_path) + primitive_keys.flatten.sort + [candidate.fetch(:type)]
          )
        surface = {
          'id' => surface_id,
          'type' => candidate.fetch(:type),
          'outer' => outer,
          'holes' => holes,
          'normal' => clean_point(candidate.fetch(:normal)),
          'area_m2' => clean_number(candidate.fetch(:area_m2)),
          'source_count' => candidate.fetch(:source_count),
          'orientation' => orientation(candidate.fetch(:normal)),
          'classification' => compact_classification(candidate.fetch(:classification))
        }
        @surface_primitive_keys[surface_id] = primitive_keys
        assign_material_id!(surface, 'front_material_id', candidate.fetch(:front_material_uuid))
        assign_material_id!(surface, 'back_material_id', candidate.fetch(:back_material_uuid))
        assign_material_id!(surface, 'inherited_material_id', candidate.fetch(:inherited_material_uuid))
        @profiler.record_surface(surface, candidate) if @profiler
        surface
      end

      def normalized_visual_edge(edge)
        definition_uuid = edge_value(edge, :definition_uuid).to_s
        source_uuid = edge_value(edge, :source_uuid).to_s
        vertices = Array(edge_value(edge, :vertices))
        unless vertices.length == 2 && vertices.all? do |point|
                 point.is_a?(Array) && point.length == 3 && point.all? { |value| value.is_a?(Numeric) && value.finite? }
               end
          raise ArgumentError, 'standalone visual edge must contain two finite XYZ vertices'
        end

        {
          definition_uuid: definition_uuid,
          source_uuid: source_uuid,
          vertices: vertices.map { |point| clean_point(point) }
        }.freeze
      end

      def edge_value(edge, key)
        edge.fetch(key) { edge.fetch(key.to_s) }
      end

      def edge_key(edge)
        [edge.fetch(:definition_uuid), edge.fetch(:source_uuid)]
      end

      def expanded_visual_edge(edge, occurrence)
        {
          'id' => stable_id('edge', occurrence.uuid_path + edge_key(edge)),
          'vertices' => edge.fetch(:vertices).map do |point|
            clean_point(transform_point(occurrence.transform, point))
          end,
          'source_count' => 1
        }
      end

      def mark_definition_coverage(definition, disposition, reason:, occurrence_path: nil)
        definition.primitive_keys.each do |primitive_key|
          @coverage.mark(
            primitive_key,
            disposition,
            reason: reason,
            occurrence_ancestry: occurrence_path
          )
        end
        @visual_edges_by_definition.fetch(definition.source_uuid, []).each do |edge|
          @coverage.mark(
            edge_key(edge),
            disposition,
            reason: reason,
            occurrence_ancestry: occurrence_path
          )
        end
      end

      def mark_surface_coverage(surface, disposition, reason)
        @surface_primitive_keys.fetch(surface.fetch('id'), []).each do |primitive_key|
          @coverage.mark(primitive_key, disposition, reason: reason)
        end
      end

      def compact_classification(classification)
        return classification.dup if @debug

        { 'method' => classification.fetch('method') }
      end

      def material_references(*values)
        result = {}
        pending = values
        until pending.empty?
          value = pending.pop
          case value
          when Hash
            value.each do |key, child|
              if Writer::MATERIAL_REFERENCE_KEYS.include?(key.to_s) && !child.nil?
                result[child] = true
              else
                pending << child
              end
            end
          when Array
            pending.concat(value)
          end
        end
        result
      end

      def topology_diagnostics(surfaces, definitions, visual_edges)
        top_level_points = surfaces.flat_map do |surface|
          surface.fetch('outer') + surface.fetch('holes').flatten(1)
        end
        top_level_points.concat(visual_edges.flat_map { |edge| edge.fetch('vertices') })
        unique = top_level_points.each_with_object({}) { |point, values| values[point] = true }
        {
          'top_level_vertex_occurrences' => top_level_points.length,
          'top_level_unique_vertices' => unique.length,
          'definition_pooled_vertices' => definitions.inject(0) do |sum, definition|
            sum + definition.dig('geometry', 'vertices').length
          end,
          'standalone_edges' => visual_edges.length + definitions.inject(0) do |sum, definition|
            sum + definition.dig('geometry', 'edges').length
          end
        }
      end

      def definition_diagnostics(retained_definitions)
        root_uuid = @snapshot.scope.root_definition_uuid
        renderable = @definitions.values.reject { |definition| definition.source_uuid == root_uuid }.count do |definition|
          !definition.primitive_keys.empty? ||
            !@visual_edges_by_definition.fetch(definition.source_uuid, []).empty?
        end
        retained_renderable = retained_definitions.count do |definition|
          geometry = definition.fetch('geometry')
          !geometry.fetch('surfaces').empty? || !geometry.fetch('edges').empty?
        end
        {
          'source_renderable' => renderable,
          'retained' => retained_definitions.length,
          'retained_renderable' => retained_renderable,
          'dropped' => [renderable - retained_renderable, 0].max
        }
      end

      def compiled_material(material)
        rgba = material.rgba.map { |channel| clean_number(channel.to_f / 255.0) }
        {
          'id' => @material_ids.fetch(material.source_uuid),
          'name' => material.name,
          'base_color_rgba' => rgba,
          'opacity' => rgba.fetch(3),
          'color_space' => 'srgb',
          'texture' => compiled_texture(material.texture)
        }
      end

      def compiled_texture(texture)
        return nil if texture.nil?

        filename = texture_value(texture, :filename).to_s
        reference = filename.empty? ? nil : File.basename(filename.tr('\\', '/'))
        {
          'reference' => reference,
          'width_m' => optional_clean_number(texture_value(texture, :width_m)),
          'height_m' => optional_clean_number(texture_value(texture, :height_m))
        }.reject { |_key, value| value.nil? }
      end

      def texture_value(texture, key)
        texture[key] || texture[key.to_s]
      end

      def optional_clean_number(value)
        value.nil? ? nil : clean_number(value)
      end

      def assign_material_id!(target, key, source_uuid)
        return target if source_uuid.nil?

        target[key] = @material_ids.fetch(source_uuid)
        target
      end

      def copy_material_ids!(target, source, keys)
        keys.each { |key| target[key] = source[key] if source.key?(key) }
        target
      end

      def orientation(normal)
        vector = normalize(normal)
        if vector[2].abs >= HORIZONTAL_NORMAL_Z_MIN
          { 'kind' => vector[2].positive? ? 'up' : 'down' }
        else
          north = @snapshot.model_context.true_north_xy
          world_azimuth = Math.atan2(vector[0], vector[1]) * 180.0 / Math::PI
          north_azimuth = Math.atan2(north[0], north[1]) * 180.0 / Math::PI
          {
            'kind' => vector[2].abs <= VERTICAL_NORMAL_Z_MAX ? 'vertical' : 'sloped',
            'azimuth_deg' => clean_number((world_azimuth - north_azimuth) % 360.0)
          }
        end
      end

      def bounds(surfaces, components, instances)
        points = surfaces.flat_map do |surface|
          surface.fetch('outer') + surface.fetch('holes').flatten(1)
        end
        points.concat(components.map do |component|
          transform = component.fetch('transform')
          [transform[12], transform[13], transform[14]]
        end)
        points.concat(instances.map do |instance|
          transform = instance.fetch('transform')
          [transform[12], transform[13], transform[14]]
        end)
        return { 'min' => [0.0, 0.0, 0.0], 'max' => [0.0, 0.0, 0.0] } if points.empty?

        {
          'min' => 3.times.map { |axis| clean_number(points.map { |point| point[axis] }.min) },
          'max' => 3.times.map { |axis| clean_number(points.map { |point| point[axis] }.max) }
        }
      end

      def stable_id(prefix, values)
        bytes = Array(values).flatten.map(&:to_s).join('|')
        "#{prefix}-#{Digest::SHA256.hexdigest(bytes)[0, 16]}"
      end

      def transform_kind(matrix)
        axes = [
          [matrix[0], matrix[1], matrix[2]],
          [matrix[4], matrix[5], matrix[6]],
          [matrix[8], matrix[9], matrix[10]]
        ]
        lengths = axes.map { |axis| vector_length(axis) }
        orthogonal = dot(axes[0], axes[1]).abs <= NORMAL_TOLERANCE &&
                     dot(axes[0], axes[2]).abs <= NORMAL_TOLERANCE &&
                     dot(axes[1], axes[2]).abs <= NORMAL_TOLERANCE
        equal_scale = lengths.max.to_f - lengths.min.to_f <= POSITION_TOLERANCE_M
        unit_scale = lengths.all? { |length| (length - 1.0).abs <= POSITION_TOLERANCE_M }
        return 'rigid' if unit_scale && orthogonal
        return 'uniform_scale' if equal_scale && orthogonal

        'non_uniform_scale'
      end

      def path_key(path)
        path.join('/')
      end

      def transform_point(matrix, point)
        [
          matrix[0] * point[0] + matrix[4] * point[1] + matrix[8] * point[2] + matrix[12],
          matrix[1] * point[0] + matrix[5] * point[1] + matrix[9] * point[2] + matrix[13],
          matrix[2] * point[0] + matrix[6] * point[1] + matrix[10] * point[2] + matrix[14]
        ]
      end

      def transform_normal(matrix, normal)
        normalize([
          matrix[0] * normal[0] + matrix[4] * normal[1] + matrix[8] * normal[2],
          matrix[1] * normal[0] + matrix[5] * normal[1] + matrix[9] * normal[2],
          matrix[2] * normal[0] + matrix[6] * normal[1] + matrix[10] * normal[2]
        ])
      end

      def loop_area(loop)
        return 0.0 if loop.length < 3

        sum = [0.0, 0.0, 0.0]
        loop.each_with_index do |point, index|
          following = loop[(index + 1) % loop.length]
          edge_cross = cross(point, following)
          3.times { |axis| sum[axis] += edge_cross[axis] }
        end
        vector_length(sum) / 2.0
      end

      def normalize(vector)
        length = vector_length(vector)
        return [0.0, 0.0, 0.0] if length <= NORMAL_TOLERANCE

        vector.map { |value| value.to_f / length }
      end

      def vector_length(vector)
        Math.sqrt(vector.inject(0.0) { |sum, value| sum + value.to_f**2 })
      end

      def subtract(left, right)
        3.times.map { |axis| left[axis] - right[axis] }
      end

      def cross(left, right)
        [
          left[1] * right[2] - left[2] * right[1],
          left[2] * right[0] - left[0] * right[2],
          left[0] * right[1] - left[1] * right[0]
        ]
      end

      def dot(left, right)
        3.times.inject(0.0) { |sum, axis| sum + left[axis] * right[axis] }
      end

      def point_key(point)
        point.map { |value| quantize(value, POSITION_TOLERANCE_M) }.join(',')
      end

      def loop_sort_key(loop)
        loop.map { |point| point_key(point) }.join('|')
      end

      def quantize(value, tolerance)
        (value.to_f / tolerance).round
      end

      def clean_point(point)
        point.map { |value| clean_number(value) }
      end

      def clean_number(value)
        rounded = value.to_f.round(SERIALIZATION_DECIMAL_PLACES)
        rounded.zero? ? 0.0 : rounded
      end

      def checkpoint(stage)
        @progress.call(stage) if @progress
      end

      def profile_occurrence(occurrence, definition, category, disposition)
        return unless @profiler

        @profiler.record_occurrence(
          occurrence,
          definition,
          category: category,
          disposition: disposition
        )
      end
    end
  end
end
