# frozen_string_literal: true

module BOMEngine
  module Tests
    module SemanticV2Fixtures
      MODEL_ID = '10000000-0000-4000-8000-000000000001'
      ROOT_FACE_ID = '20000000-0000-4000-8000-000000000002'
      SHARED_DEFINITION_ID = '30000000-0000-4000-8000-000000000003'
      SHARED_FACE_ID = '40000000-0000-4000-8000-000000000004'
      FIRST_INSTANCE_ID = '50000000-0000-4000-8000-000000000005'
      SECOND_INSTANCE_ID = '60000000-0000-4000-8000-000000000006'
      GROUP_DEFINITION_ID = '70000000-0000-4000-8000-000000000007'
      GROUP_INSTANCE_ID = '80000000-0000-4000-8000-000000000008'
      GROUP_FACE_ID = '90000000-0000-4000-8000-000000000009'
      HIDDEN_FACE_ID = 'a0000000-0000-4000-8000-00000000000a'
      POLICY_FACE_ID = 'b0000000-0000-4000-8000-00000000000b'
      ADJACENT_FACE_ID = 'c0000000-0000-4000-8000-00000000000c'
      MATERIAL_ID = 'd0000000-0000-4000-8000-00000000000d'
      TEXT_ID = 'e0000000-0000-4000-8000-00000000000e'
      SECOND_MATERIAL_ID = 'f0000000-0000-4000-8000-00000000000f'
      NESTED_INSTANCE_ID = '11000000-0000-4000-8000-000000000011'

      Fixture = Struct.new(
        :model, :roots, :identity_plan, :shared_definition, :first_instance,
        :second_instance, :group_instance, :nested_instance, :root_face, :hidden_face,
        :policy_face, :shared_face, :adjacent_face, :material, :second_material,
        keyword_init: true
      )

      class FakeIdentityPlan
        attr_reader :model_id, :lookups
        attr_accessor :foreign_source_provenance

        def initialize(model_id, source_uuids)
          @model_id = model_id
          @source_uuids = source_uuids
          @lookups = []
          @foreign_source_provenance = [].freeze
        end

        def source_uuid_for(entity)
          @lookups << [:source, entity]
          @source_uuids.fetch(entity)
        end

        def occurrence_uuid_for(entity)
          @lookups << [:occurrence, entity]
          @source_uuids.fetch(entity)
        end

        def forget(entity)
          @source_uuids.delete(entity)
        end

        def remember(entity, source_uuid)
          @source_uuids[entity] = source_uuid
        end
      end

      class FakeModel
        attr_reader :entities, :materials, :operation_calls, :writes, :shadow_info
        attr_accessor :active_path

        def initialize(entities:, materials:)
          @entities = entities
          @materials = materials
          @operation_calls = []
          @writes = []
          @active_path = []
          @shadow_info = { 'NorthAngle' => 0.0 }
        end

        def start_operation(*args)
          @operation_calls << args
          raise 'extractor must not open a model operation'
        end

        def set_attribute(*args)
          @writes << args
          raise 'extractor must not write the model'
        end
      end

      class FakeTransformation
        attr_reader :values

        def initialize(values)
          @values = values.freeze
        end

        def to_a
          @values
        end

        def self.translation(x, y, z)
          new([
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            x.to_f, y.to_f, z.to_f, 1.0
          ])
        end

        def self.identity
          translation(0, 0, 0)
        end
      end

      FakePoint = Struct.new(:x, :y, :z)
      FakeVertex = Struct.new(:position)

      class FakeEdge
        attr_reader :faces

        def initialize
          @faces = []
        end
      end

      class FakeLoop
        attr_reader :vertices, :edges

        def initialize(points, outer:)
          @outer = outer
          @vertices = points.map { |point| FakeVertex.new(FakePoint.new(*point)) }
          @edges = points.map { FakeEdge.new }
        end

        def outer?
          @outer
        end
      end

      class FakeTag
        attr_accessor :name

        def initialize(name, visible: true)
          @name = name
          @visible = visible
        end

        def visible?
          @visible
        end
      end

      FakeColor = Struct.new(:red, :green, :blue, :alpha)

      class FakeMaterial
        attr_reader :name, :color, :alpha
        attr_accessor :texture

        def initialize(name, rgba)
          @name = name
          @color = FakeColor.new(*rgba)
          @alpha = rgba.fetch(3) / 255.0
          @texture = nil
        end
      end

      class FakeFace
        attr_accessor :name, :layer, :material, :back_material, :policy_excluded
        attr_reader :loops, :normal, :area

        def initialize(outer:, holes: [], normal: [0, 0, 1], area: 1.0, hidden: false,
                       policy_excluded: false, material: nil, layer: nil)
          @loops = [FakeLoop.new(outer, outer: true)] + holes.map { |points| FakeLoop.new(points, outer: false) }
          @normal = FakePoint.new(*normal)
          @area = area
          @hidden = hidden
          @policy_excluded = policy_excluded
          @material = material
          @back_material = nil
          @layer = layer || FakeTag.new('Untagged')
          @name = ''
          @attributes = {}
          @loops.each { |loop| loop.edges.each { |edge| edge.faces << self } }
        end

        def hidden?
          @hidden
        end

        def visible?
          !@hidden
        end

        def set_attribute(dictionary, key, value)
          @attributes[[dictionary, key]] = value
        end

        def get_attribute(dictionary, key, default = nil)
          @attributes.fetch([dictionary, key], default)
        end
      end

      class FakeDefinition
        attr_accessor :name
        attr_reader :entities

        def initialize(name:, entities:, kind: 'component')
          @name = name
          @entities = entities
          @group = kind == 'group'
        end

        def group?
          @group
        end
      end

      class FakeInstance
        attr_accessor :name, :transformation, :layer, :material
        attr_reader :definition, :kind

        def initialize(definition:, transformation:, name:, kind: 'component', hidden: false, layer: nil)
          @definition = definition
          @transformation = transformation
          @name = name
          @kind = kind
          @hidden = hidden
          @layer = layer || FakeTag.new('Untagged')
          @material = nil
        end

        def hidden?
          @hidden
        end

        def visible?
          !@hidden
        end
      end

      class FakeText
        attr_reader :text

        def initialize(text:, target: nil, path: nil)
          @text = text
          @path = path || [target]
        end

        def attached_to
          [@path, FakePoint.new(0, 0, 0)]
        end
      end

      module_function

      def complex_fixture
        material = FakeMaterial.new('Concrete', [120, 121, 122, 255])
        second_material = FakeMaterial.new('Concrete Alternate', [120, 121, 122, 255])
        root_face = FakeFace.new(
          outer: [[0, 0, 0], [2, 0, 0], [2, 2, 0], [0, 2, 0]],
          area: 4.0,
          material: material
        )
        hidden_face = FakeFace.new(
          outer: [[3, 0, 0], [4, 0, 0], [4, 1, 0], [3, 1, 0]],
          hidden: true
        )
        policy_face = FakeFace.new(
          outer: [[5, 0, 0], [6, 0, 0], [6, 1, 0], [5, 1, 0]],
          policy_excluded: true
        )
        adjacent_face = FakeFace.new(
          outer: [[0, 0, 0], [0, 2, 0], [-1, 2, 0], [-1, 0, 0]],
          area: 2.0
        )
        shared_face = FakeFace.new(
          outer: [[0, 0, 0], [4, 0, 0], [4, 4, 0], [0, 4, 0]],
          holes: [[[1, 1, 0], [1, 3, 0], [3, 3, 0], [3, 1, 0]]],
          area: 12.0,
          material: material
        )
        shared_face.loops.first.edges.first.faces << adjacent_face
        shared_definition = FakeDefinition.new(name: 'Door Component', entities: [shared_face])
        first_instance = FakeInstance.new(
          definition: shared_definition,
          transformation: FakeTransformation.translation(10, 0, 0),
          name: 'Pintu cadangan'
        )
        second_instance = FakeInstance.new(
          definition: shared_definition,
          transformation: FakeTransformation.translation(20, 0, 0),
          name: 'Second Door'
        )
        group_face = FakeFace.new(
          outer: [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]],
          area: 1.0
        )
        nested_instance = FakeInstance.new(
          definition: shared_definition,
          transformation: FakeTransformation.translation(1, 0, 0),
          name: 'Nested Door'
        )
        group_definition = FakeDefinition.new(
          name: 'Nested Group Definition',
          entities: [group_face, nested_instance],
          kind: 'group'
        )
        group_instance = FakeInstance.new(
          definition: group_definition,
          transformation: FakeTransformation.translation(0, 5, 0),
          name: 'Nested Group',
          kind: 'group'
        )
        group_instance.material = second_material
        attached_text = FakeText.new(
          text: 'Pintu Utama',
          path: [first_instance, shared_face.loops.first.edges.first]
        )
        roots = [root_face, first_instance, second_instance, group_instance, hidden_face, policy_face, attached_text]
        model = FakeModel.new(entities: roots, materials: [material, second_material])
        source_uuids = {
          root_face => ROOT_FACE_ID,
          shared_definition => SHARED_DEFINITION_ID,
          shared_face => SHARED_FACE_ID,
          first_instance => FIRST_INSTANCE_ID,
          second_instance => SECOND_INSTANCE_ID,
          group_definition => GROUP_DEFINITION_ID,
          group_instance => GROUP_INSTANCE_ID,
          nested_instance => NESTED_INSTANCE_ID,
          group_face => GROUP_FACE_ID,
          hidden_face => HIDDEN_FACE_ID,
          policy_face => POLICY_FACE_ID,
          adjacent_face => ADJACENT_FACE_ID,
          material => MATERIAL_ID,
          second_material => SECOND_MATERIAL_ID,
          attached_text => TEXT_ID
        }
        fixture_faces = [root_face, hidden_face, policy_face, adjacent_face,
                         shared_face, group_face]
        fixture_faces.flat_map { |face| face.loops.flat_map(&:edges) }.uniq.each_with_index do |edge, index|
          source_uuids[edge] = format(
            '%08x-0000-4000-8000-%012x',
            0x71000000 + index,
            0x100 + index
          )
        end
        Fixture.new(
          model: model,
          roots: roots,
          identity_plan: FakeIdentityPlan.new(MODEL_ID, source_uuids),
          shared_definition: shared_definition,
          first_instance: first_instance,
          second_instance: second_instance,
          group_instance: group_instance,
          nested_instance: nested_instance,
          root_face: root_face,
          hidden_face: hidden_face,
          policy_face: policy_face,
          shared_face: shared_face,
          adjacent_face: adjacent_face,
          material: material,
          second_material: second_material
        )
      end
    end
  end
end
