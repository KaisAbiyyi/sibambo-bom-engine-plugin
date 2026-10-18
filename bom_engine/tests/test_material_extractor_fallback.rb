# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require_relative '../material_extractor'

class TestMaterialExtractorFallback < Test::Unit::TestCase
  Color = Struct.new(:red, :green, :blue, :alpha)
  Image = Struct.new(:bytes) do
    def save_file(path)
      File.binwrite(path, bytes)
    end
  end
  Texture = Struct.new(:filename, :width, :height, :image_width, :image_height) do
    def image_rep(displayed)
      raise 'Expected displayed pixels' unless displayed
      Image.new("\x89PNG\r\nembedded-pixel-fixture".b)
    end
  end
  Material = Struct.new(:name, :texture) do
    def display_name; name; end
    def color; Color.new(1, 2, 3, 255); end
    def alpha; 1.0; end
    def materialType; 1; end
  end
  Model = Struct.new(:materials)

  def test_missing_external_texture_is_replaced_by_embedded_displayed_pixels
    original = BOMEngine::BOMCTextureOptimizer.method(:stage)
    BOMEngine::BOMCTextureOptimizer.define_singleton_method(:stage) do |**_args|
      raise 'Could not open /Users/macpro/missing-texture.jpg'
    end
    Dir.mktmpdir('texture-fallback') do |dir|
      material = Material.new('stale-source', Texture.new('/Users/macpro/missing-texture.jpg', 1, 1, 1, 1))
      result = BOMEngine::MaterialExtractor.extract(Model.new([material]), nil, dir,
        optimize_textures: true, profile: :exact)
      texture = result.first.fetch(:texture)
      assert_equal :displayed_pixel_fallback, texture.dig(:staging_evidence, :reason)
      assert_equal "\x89PNG\r\nembedded-pixel-fixture".b, texture.fetch(:bytes)
      assert_equal File.basename(texture.fetch(:filename)), texture.fetch(:filename)
      assert_equal Digest::SHA256.hexdigest(texture.fetch(:bytes)), texture.fetch(:sha256)
      assert File.file?(File.join(dir, texture.fetch(:filename)))
    end
  ensure
    BOMEngine::BOMCTextureOptimizer.define_singleton_method(:stage) { |**kwargs, &block| original.call(**kwargs, &block) } if original
  end
end
