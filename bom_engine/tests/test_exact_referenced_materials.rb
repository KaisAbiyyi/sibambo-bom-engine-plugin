# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require_relative 'sketchup_mock_helper'
require_relative '../core'

class TestExactReferencedMaterials < Test::Unit::TestCase
  Pixel = Struct.new(:width, :height, :bits_per_pixel, :row_padding, :data)
  class UV
    def get_front_UVQ(point)
      Geom::Vector3d.new(point.x, point.y, 1.0)
    end

    def get_back_UVQ(point)
      Geom::Vector3d.new(point.x + 2.0, point.y + 3.0, 1.0)
    end
  end

  class Texture
    def filename; 'fixture.png'; end
    def width; 1.0; end
    def height; 1.0; end
    def image_width; 1; end
    def image_height; 1; end

    def image_rep(_displayed)
      Pixel.new(1, 1, 24, 0, [103, 47, 11].pack('C*'))
    end

    def write(path, displayed)
      BOMEngine::MaterialExtractor.write_pixel_fallback_png(image_rep(displayed), path)
      true
    end
  end

  def setup
    @original_texture_writer = Sketchup.method(:create_texture_writer)
    Sketchup.define_singleton_method(:create_texture_writer) { Object.new }
  end

  def teardown
    Sketchup.define_singleton_method(:create_texture_writer, @original_texture_writer)
  end

  def capture_fixture
    model = Sketchup::Model.new
    model.materials.add('Unused enumerated')
    image = Sketchup::Material.new('Referenced texture')
    image.define_singleton_method(:persistent_id) { 42 }
    image.texture = Texture.new
    group = model.entities.add_group
    group.material = image
    face = group.entities.add_face([0, 0, 0], [1, 0, 0], [0, 1, 0])
    face.define_singleton_method(:get_UVHelper) { |*_args| UV.new }
    face.material = image
    back_wrapper = image.dup
    back_wrapper.define_singleton_method(:persistent_id) { 42 }
    face.back_material = back_wrapper
    group.entities.add_face([2, 0, 0], [3, 0, 0], [2, 1, 0])
    [model, group]
  end

  def snapshot(model, directory, profile)
    BOMEngine::BOMCExtension.send(:snapshot_model, model, directory, ->(**_event) {}, profile: profile)
  end

  def test_exact_writer_keeps_an_unenumerated_dual_sided_material_and_uv
    model, = capture_fixture
    Dir.mktmpdir('exact-refs') do |dir|
      graph = snapshot(model, dir, :exact)
      names = graph[:materials].map { |row| row[:name] }
      assert_equal ['Unused enumerated', 'Referenced texture'], names
      staged = graph[:materials].last.fetch(:texture)
      assert_equal Digest::SHA256.hexdigest(staged.fetch(:bytes)), staged[:sha256]
      assert_operator staged.fetch(:bytes).bytesize, :>, 0

      encoded = BOMEngine::BOMCWriter.pack(graph, profile: :exact, source_skp_bytes: 1_000_000)
      decoded = BOMEngine::BOMCDecoder.decode(encoded.fetch(:bytes))
      assert_equal :exact, decoded.dig(:encoding_contract, :profile)
      faces = decoded[:meshes].flat_map { |mesh| mesh[:faces] }
      painted, default = faces
      assert_equal [1, 1, true, true], painted.values_at(:front_material, :back_material, :has_front_uv, :has_back_uv)
      assert_equal [nil, nil, false, false], default.values_at(:front_material, :back_material, :has_front_uv, :has_back_uv)
      assert_equal [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]], painted.dig(:uv, :front_outer)
      assert_equal [[2.0, 3.0], [3.0, 3.0], [2.0, 4.0]], painted.dig(:uv, :back_outer)
      assert_equal 'Referenced texture', decoded[:materials][1][:name]
      group_instance = decoded[:instances].find { |instance| instance[:kind].to_s == 'group_instance' }
      assert_equal 1, group_instance.fetch(:material)
      texture_index = decoded[:materials][1].fetch(:texture)
      pixels = decoded[:textures].fetch(texture_index)
      assert_equal [1, 1], pixels.values_at(:image_width_px, :image_height_px)
      assert_equal staged[:bytes], pixels[:bytes]
      assert_equal ['Unused enumerated'], model.materials.map(&:name)
    end
  end

  def test_visual_still_uses_the_enumerated_inventory
    model, = capture_fixture
    Dir.mktmpdir('visual-refs') do |dir|
      graph = snapshot(model, dir, :visual)
      assert_equal ['Unused enumerated'], graph[:materials].map { |row| row[:name] }
    end
  end

  def test_exact_rejects_two_material_identities_with_one_name
    model, group = capture_fixture
    conflicting = Sketchup::Material.new('Referenced texture')
    conflicting.define_singleton_method(:persistent_id) { 43 }
    group.entities.find { |entity| entity.is_a?(Sketchup::Face) }.back_material = conflicting
    Dir.mktmpdir('exact-conflict') do |dir|
      error = assert_raise(ArgumentError) { snapshot(model, dir, :exact) }
      assert_match(/material name conflict/, error.message)
    end
  end

  # Review 5986296045 item 2: fail-closed identity cases not covered above.
  def painted_face(group)
    group.entities.find { |entity| entity.is_a?(Sketchup::Face) }
  end

  def unenumerated_reference(name, pid)
    material = Sketchup::Material.new(name)
    material.define_singleton_method(:persistent_id) { pid } unless pid == :absent
    material
  end

  def test_exact_rejects_a_referenced_material_without_persistent_identity
    # :absent = no persistent_id method; 0, negative and non-Integer values are not identities.
    [:absent, nil, 0, -5, 'pid_text'].each do |pid|
      model, group = capture_fixture
      painted_face(group).back_material = unenumerated_reference('No identity', pid)
      Dir.mktmpdir('exact-no-pid') do |dir|
        error = assert_raise(ArgumentError, "pid=#{pid.inspect}") { snapshot(model, dir, :exact) }
        assert_match(/Missing persistent identity for referenced material No identity/, error.message)
      end
    end
  end

  def test_exact_rejects_one_persistent_identity_with_conflicting_names
    model, group = capture_fixture
    painted_face(group).back_material = unenumerated_reference('Renamed texture', 42)
    Dir.mktmpdir('exact-pid-rename') do |dir|
      error = assert_raise(ArgumentError) { snapshot(model, dir, :exact) }
      assert_match(/Conflicting names for material identity 42/, error.message)
    end
  end

  def test_visual_inventory_is_unaffected_by_exact_identity_guards
    model, group = capture_fixture
    painted_face(group).back_material = unenumerated_reference('No identity', :absent)
    Dir.mktmpdir('visual-no-pid') do |dir|
      graph = snapshot(model, dir, :visual)
      assert_equal ['Unused enumerated'], graph[:materials].map { |row| row[:name] }
    end
  end

  def test_rejected_exact_capture_compiles_and_publishes_nothing
    model, group = capture_fixture
    painted_face(group).back_material = unenumerated_reference('No identity', :absent)
    Dir.mktmpdir('exact-job') do |dir|
      output_path = File.join(dir, 'm09.bomc')
      calls = []
      context = {
        clock: -> { 0.0 }, on_yield: ->(_event) {}, cancelled: -> { false },
        source_info: ->(_model) { { path: nil, bytes: nil, available: false } },
        snapshot: ->(source_model, _checkpoint) { snapshot(source_model, File.join(dir, 'textures'), :exact) },
        compile: ->(*_args) { calls << :compile },
        validate: ->(_result) { calls << :validate },
        publish: ->(*_args) { calls << :publish },
        cleanup: -> { calls << :cleanup }
      }
      error = assert_raise(ArgumentError) do
        BOMEngine::BOMCExportJob.run(model: model, output_path: output_path,
                                     settings: BOMEngine::BOMCProcessing.settings(:balanced), context: context)
      end
      assert_match(/Missing persistent identity/, error.message)
      assert_equal [:cleanup], calls
      assert_equal false, File.exist?(output_path)
      assert_equal [], Dir.glob(File.join(dir, '*.part'))
    end
  end
end
