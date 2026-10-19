# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../material_extractor'

class TestBOMCJcmBudgetPriority < Minitest::Test
  Color = Struct.new(:red, :green, :blue, :alpha)
  Material = Struct.new(:object_id, :name, :display_name, :color, :alpha, :materialType, :texture)
  Model = Struct.new(:materials)

  class Texture
    attr_reader :filename, :width, :height, :image_width, :image_height
    def initialize(filename, image_width, image_height)
      @filename = filename
      @width = @height = 1.0
      @image_width = image_width
      @image_height = image_height
    end
  end

  def material(id, name, filename, width, height)
    Material.new(id, name, name, Color.new(255,255,255,255), 1.0, 1, Texture.new(filename, width, height))
  end

  def test_uses_128m_budget_and_prioritizes_large_jpegs_without_output_reordering
    calls = []
    optimizer = BOMEngine::BOMCTextureOptimizer
    original = optimizer.method(:stage)
    optimizer.define_singleton_method(:stage) do |**kwargs, &block|
      calls << [kwargs[:source_path], kwargs[:color_map_budget][:remaining_pixels]]
      path = File.join(kwargs[:directory], "#{kwargs[:basename]}.png")
      File.binwrite(path, 'x')
      { path: path, filename: File.basename(path), evidence: { selected: :staged_png } }
    end

    source = [
      material(1, 'Small', 'small.jpg', 100, 100),
      material(2, 'Png', 'large.png', 4000, 4000),
      material(3, 'Large', 'large.jpg', 8000, 8000)
    ]
    Dir.mktmpdir('jcm-budget-priority') do |dir|
      result = BOMEngine::MaterialExtractor.extract(Model.new(source), nil, dir,
        optimize_textures: true, profile: :exact, allow_jpeg_color_map: true)
      assert_equal ['Small', 'Png', 'Large'], result.map { |row| row[:name] }
    end

    assert_equal ['large.jpg', 'small.jpg', 'large.png'], calls.map(&:first)
    assert_equal [128_000_000], calls.map { |row| row[1] }.uniq
  ensure
    optimizer.define_singleton_method(:stage, original) if original
  end
end
