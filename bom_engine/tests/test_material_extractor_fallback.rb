# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'zlib'
require_relative '../material_extractor'

class TestMaterialExtractorFallback < Test::Unit::TestCase
  Color = Struct.new(:red, :green, :blue, :alpha)
  Image = Struct.new(:bytes) do
    def save_file(path)
      File.binwrite(path, bytes)
    end
  end
  UnsaveableImage = Struct.new(:width, :height, :bits_per_pixel, :row_padding, :data) do
    def save_file(_path)
      raise 'failed to save image'
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

  def test_native_image_save_failure_uses_lossless_embedded_bgra_pixels
    original = BOMEngine::BOMCTextureOptimizer.method(:stage)
    BOMEngine::BOMCTextureOptimizer.define_singleton_method(:stage) do |**_args|
      raise 'SketchUp could not stage the lossless PNG texture'
    end
    # Windows ImageRep supplies BGRA, with alpha intact.
    image = UnsaveableImage.new(2, 1, 32, 0, [3, 2, 1, 17, 7, 6, 5, 255].pack('C*'))
    texture_class = Class.new(Texture) do
      define_method(:image_rep) { |displayed| raise 'not displayed' unless displayed; image }
    end
    Dir.mktmpdir('texture-raw-png') do |dir|
      mat = Material.new('foreign-path', texture_class.new('/Users/macpro/broken.jpg', 1, 1, 2, 1))
      tex = BOMEngine::MaterialExtractor.extract(Model.new([mat]), nil, dir, optimize_textures: true, profile: :exact).first.fetch(:texture)
      assert_equal :raw_pixel_png, tex.dig(:staging_evidence, :fallback_method)
      assert_equal :displayed_pixel_fallback, tex.dig(:staging_evidence, :reason)
      path = File.join(dir, tex.fetch(:filename))
      contents = File.binread(path)
      assert_equal "\x89PNG\r\n\x1a\n".b, contents.byteslice(0, 8)
      assert_equal Digest::SHA256.hexdigest(contents), tex.fetch(:sha256)
      assert_equal 6, contents.byteslice(25, 1).unpack1('C'), 'RGBA PNG must retain alpha'
      packed = png_pixels(contents)
      expected = Gem.win_platform? ? [1, 2, 3, 17, 5, 6, 7, 255] : [3, 2, 1, 17, 7, 6, 5, 255]
      assert_equal [0, *expected].pack('C*'), packed
    end
  ensure
    BOMEngine::BOMCTextureOptimizer.define_singleton_method(:stage) { |**kwargs, &block| original.call(**kwargs, &block) } if original
  end

  def test_raw_png_preserves_row_padding_and_rejects_short_pixel_buffer
    Dir.mktmpdir('texture-raw-padding') do |dir|
      image = UnsaveableImage.new(1, 2, 24, 1, [7, 8, 9, 0, 10, 11, 12, 0].pack('C*'))
      path = File.join(dir, 'padding.png')
      BOMEngine::MaterialExtractor.write_pixel_fallback_png(image, path)
      pixels = png_pixels(File.binread(path))
      expected = Gem.win_platform? ? [9, 8, 7, 12, 11, 10] : [7, 8, 9, 10, 11, 12]
      assert_equal [0, *expected.first(3), 0, *expected.last(3)].pack('C*'), pixels
      image.data = "\x00\x01".b
      assert_raise(ArgumentError) { BOMEngine::MaterialExtractor.write_pixel_fallback_png(image, path) }
      assert !File.exist?(path), 'invalid raw data must not leave a misleading PNG'
    end
  end

  def png_pixels(bytes)
    offset = 8
    compressed = ''.b
    while offset < bytes.bytesize
      length = bytes.byteslice(offset, 4).unpack1('N')
      type = bytes.byteslice(offset + 4, 4)
      compressed << bytes.byteslice(offset + 8, length) if type == 'IDAT'
      offset += length + 12
      break if type == 'IEND'
    end
    Zlib::Inflate.inflate(compressed)
  end
end
