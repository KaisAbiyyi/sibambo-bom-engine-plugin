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

  # The live SketchUp serializers use legacy Windows paths. Portable Ruby 3.3
  # accepts longer paths, so model that host boundary rather than relying on
  # the test runner to fail the same way as SketchUp's embedded Ruby.
  class NativePathImage < UnsaveableImage
    attr_accessor :reject_save

    def save_file(path)
      raise 'failed to save image' if reject_save || File.expand_path(path).length >= 260
      File.binwrite(path, data)
    end
  end

  class NativePathTexture < Texture
    attr_accessor :reject_write, :image

    def write(path, displayed)
      raise 'Expected displayed pixels' unless displayed
      return false if reject_write || File.expand_path(path).length >= 260
      File.binwrite(path, image.data)
      true
    end

    def image_rep(displayed)
      raise 'Expected displayed pixels' unless displayed
      image
    end
  end

  def with_native_path_fixture
    original_encoder = BOMEngine::BOMCTextureEncoder.configured_binary_path
    Dir.mktmpdir('native-path') do |root|
      # The actual failing texture directory is 197 characters long.
      dir = File.join(root, 'n' * (197 - File.expand_path(root).length - 1))
      FileUtils.mkdir_p(dir)
      BOMEngine::BOMCTextureEncoder.configured_binary_path = File.join(root, 'absent-cwebp.exe')
      image = NativePathImage.new(1, 1, 32, 0, [3, 2, 1, 17].pack('C*'))
      texture = NativePathTexture.new('/Users/macpro/missing.jpg', 1, 1, 1, 1)
      texture.image = image
      name = 'stone-flooring-texture-google-search-room-design-reference-inside-ideas-1'
      yield dir, Material.new(name, texture)
    end
  ensure
    BOMEngine::BOMCTextureEncoder.configured_binary_path = original_encoder
  end

  def test_long_material_name_does_not_break_native_png_staging
    with_native_path_fixture do |dir, material|
      result = BOMEngine::MaterialExtractor.extract(Model.new([material]), nil, dir,
        optimize_textures: true, profile: :visual).first
      texture = result.fetch(:texture)
      assert_equal material.name, result.fetch(:name), 'display names retain their original identity'
      assert_not_equal :displayed_pixel_fallback, texture.dig(:staging_evidence, :reason),
        'native PNG staging must succeed without a path-induced fallback'
      assert_operator File.join(dir, texture.fetch(:filename)).length, :<, 260
      # Reserve room for the longest existing WebP decode suffix as well.
      assert_operator File.join(dir, File.basename(texture.fetch(:filename), '.*') +
        '.lossless-m6-q100-mt.webp.decoded.png').length, :<, 260
      assert_equal material.texture.image.data, texture.fetch(:bytes)
    end
  end

  def test_long_material_name_keeps_native_image_fallback_path_short
    with_native_path_fixture do |dir, material|
      material.texture.reject_write = true
      texture = BOMEngine::MaterialExtractor.extract(Model.new([material]), nil, dir,
        optimize_textures: true, profile: :exact).first.fetch(:texture)
      assert_equal :image_rep_save, texture.dig(:staging_evidence, :fallback_method)
      assert_operator File.join(dir, texture.fetch(:filename)).length, :<, 260
      assert_equal material.texture.image.data, texture.fetch(:bytes)
    end
  end

  def test_long_material_name_keeps_raw_pixel_fallback_path_short
    with_native_path_fixture do |dir, material|
      material.texture.reject_write = true
      material.texture.image.reject_save = true
      texture = BOMEngine::MaterialExtractor.extract(Model.new([material]), nil, dir,
        optimize_textures: true, profile: :exact).first.fetch(:texture)
      assert_equal :raw_pixel_png, texture.dig(:staging_evidence, :fallback_method)
      assert_operator File.join(dir, texture.fetch(:filename)).length, :<, 260
      expected = Gem.win_platform? ? [0, 1, 2, 3, 17] : [0, 3, 2, 1, 17]
      assert_equal expected.pack('C*'), png_pixels(texture.fetch(:bytes))
    end
  end

  def test_duplicate_material_names_cannot_overwrite_fallback_textures
    with_native_path_fixture do |dir, first|
      first.texture.reject_write = true
      second_texture = NativePathTexture.new('/Users/macpro/also-missing.jpg', 1, 1, 1, 1)
      second_texture.reject_write = true
      second_texture.image = NativePathImage.new(1, 1, 32, 0, [6, 5, 4, 17].pack('C*'))
      second = Material.new(first.name, second_texture)
      rows = BOMEngine::MaterialExtractor.extract(Model.new([first, second]), nil, dir,
        optimize_textures: true, profile: :exact)
      textures = rows.map { |row| row.fetch(:texture) }
      assert_equal 2, textures.map { |texture| texture.fetch(:filename) }.uniq.length
      textures.each do |texture|
        bytes = File.binread(File.join(dir, texture.fetch(:filename)))
        assert_equal texture.fetch(:bytes), bytes
        assert_equal texture.fetch(:sha256), Digest::SHA256.hexdigest(bytes)
      end
    end
  end

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
