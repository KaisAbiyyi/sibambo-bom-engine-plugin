# frozen_string_literal: true
require 'test/unit'
require 'tmpdir'
require_relative '../../tools/history/probe_exact_texture'

class TestExactTextureProbe < Test::Unit::TestCase
  Frame = Struct.new(:width, :height, :bits_per_pixel, :row_padding, :data)
  Texture = Struct.new(:filename, :image_width, :image_height, :pixels) do
    def write(path, colorize)
      raise 'probe must extract without colorization' if colorize
      File.binwrite(path, 'embedded-jpeg')
      true
    end
    def image_rep(_colorized)
      pixels
    end
  end
  Material = Struct.new(:name, :texture)
  Model = Struct.new(:path, :materials) do
    def modified?; false; end
  end

  def rgb
    Frame.new(2, 1, 24, 0, [1, 2, 3, 4, 5, 6].pack('C*'))
  end

  def test_exact_equality_includes_alpha_and_ignores_padding
    rgba = Frame.new(2, 1, 32, 1, [1, 2, 3, 255, 4, 5, 6, 255, 99].pack('C*'))
    assert_equal true, ExactTextureProbe.same_pixels?(rgb, rgba)
    rgba.data.setbyte(7, 254)
    assert_equal false, ExactTextureProbe.same_pixels?(rgb, rgba)
    rgba.data.setbyte(7, 255)
    rgba.data.setbyte(6, 7)
    assert_equal false, ExactTextureProbe.same_pixels?(rgb, rgba)
    assert_raise(ArgumentError) { ExactTextureProbe.same_pixels?(rgb, Frame.new(2, 1, 24, 0, '')) }
  end

  def test_probe_is_bounded_isolated_and_not_certification
    Dir.mktmpdir do |root|
      model_path = File.join(root, 'arbitrary.skp')
      File.binwrite(model_path, 'source')
      materials = [
        Material.new('small', Texture.new('embedded.jpg', 1, 1, rgb)),
        Material.new('../unsafe-name', Texture.new('somewhere.jpeg', 2, 1, rgb)),
        Material.new('too-large', Texture.new('huge.jpg', 10_000, 10_000, rgb)),
        Material.new('png', Texture.new('image.png', 2, 1, rgb))
      ]
      session = ExactTextureProbe.run(model: Model.new(model_path, materials), output_root: root,
        loader: ->(_) { rgb }, limit: 1)
      report = JSON.parse(File.read(File.join(session, 'report.json')))
      assert_equal 'probe_complete', report['status']
      assert_equal false, report['ready']
      assert_equal 1, report['textures'].length
      assert_equal '../unsafe-name', report['textures'][0]['material']
      assert_equal true, report['textures'][0]['pixel_identical']
      assert_equal Digest::SHA256.hexdigest('embedded-jpeg'), report['textures'][0]['sha256']
      assert_equal 'source', File.binread(model_path)
      assert_equal ['texture-0.jpg'], Dir.children(session).grep(/\.jpg$/)
    end
  end

  def test_mismatch_is_reported_not_accepted
    Dir.mktmpdir do |root|
      model_path = File.join(root, 'model.skp')
      File.binwrite(model_path, 'source')
      texture = Texture.new('embedded.jpg', 2, 1, rgb)
      changed = rgb
      changed.data.setbyte(5, 9)
      session = ExactTextureProbe.run(model: Model.new(model_path, [Material.new('m', texture)]),
        output_root: root, loader: ->(_) { changed })
      report = JSON.parse(File.read(File.join(session, 'report.json')))
      assert_equal false, report['textures'][0]['pixel_identical']
      assert_equal false, report['ready']
    end
  end

  def test_rejects_unsaved_changes_and_invalid_limits
    model = Model.new('', [])
    assert_raise(ArgumentError) { ExactTextureProbe.run(model: model, limit: 0) }
    assert_raise(RuntimeError) { ExactTextureProbe.run(model: model) }
  end

  def test_inventory_checks_more_than_three_textures_without_saving_raw_frames
    Dir.mktmpdir do |root|
      path = File.join(root, 'model.skp')
      File.binwrite(path, 'source')
      materials = 4.times.map { |i| Material.new("m#{i}", Texture.new('image.jpg', 2, 1, rgb)) }
      session = ExactTextureProbe.run(model: Model.new(path, materials), output_root: root,
        loader: ->(_) { rgb }, limit: 64, capture_pixels: false)
      report = JSON.parse(File.read(File.join(session, 'report.json')))
      assert_equal 4, report['textures'].length
      assert_equal false, report['capture_pixels']
      assert_equal 4, report['eligible_texture_count']
      assert_equal 0, report['eligible_textures_not_sampled']
      assert Dir.glob(File.join(session, '*.raw.gz')).empty?
      assert report['textures'].all? { |entry| entry['pixel_identical'] == true }
    end
  end

  def test_explicit_large_texture_inventory_keeps_a_hard_cap_and_excludes_small_ones
    Dir.mktmpdir do |root|
      path = File.join(root, 'model.skp')
      File.binwrite(path, 'source')
      materials = [Material.new('small', Texture.new('s.jpg', 2, 1, rgb)),
        Material.new('large', Texture.new('l.jpg', 3000, 2000, rgb)),
        Material.new('too_large', Texture.new('x.jpg', 10_000, 10_000, rgb))]
      session = ExactTextureProbe.run(model: Model.new(path, materials), output_root: root,
        loader: ->(_) { rgb }, limit: 64, capture_pixels: false,
        min_pixels: 4_000_001, max_pixels: 32_000_000)
      report = JSON.parse(File.read(File.join(session, 'report.json')))
      assert_equal ['large'], report['textures'].map { |t| t['material'] }
      assert_equal 1, report['oversized_jpeg_textures_skipped']
      assert_raise(ArgumentError) { ExactTextureProbe.run(max_pixels: 32_000_001) }
    end
  end

  # Rejecting a JPEG without preserving both reference domains hides whether
  # material colorization or the image round trip caused the mismatch.
  def test_keeps_pixel_evidence_and_separates_colorization_from_jpeg_roundtrip
    Dir.mktmpdir do |root|
      path = File.join(root, 'model.skp')
      File.binwrite(path, 'source')
      original = rgb
      displayed = rgb
      displayed.data.setbyte(0, 9)
      texture = Texture.new('embedded.jpg', 2, 1, original)
      texture.define_singleton_method(:image_rep) { |colorized| colorized ? displayed : original }
      session = ExactTextureProbe.run(model: Model.new(path, [Material.new('m', texture)]),
        output_root: root, loader: ->(_) { original })
      entry = JSON.parse(File.read(File.join(session, 'report.json')))['textures'][0]
      assert_equal true, entry['colorization_changes_pixels']
      assert_equal true, entry['jpeg_matches_uncolorized']
      assert_equal false, entry['pixel_identical']
      %w[colorized uncolorized jpeg_decoded].each do |name|
        artifact = entry.fetch('pixel_evidence').fetch(name)
        bytes = Zlib::GzipReader.open(File.join(session, artifact['file']), &:read)
        assert_equal(name == 'colorized' ? [9, 2, 3, 4, 5, 6] : [1, 2, 3, 4, 5, 6], bytes.bytes)
        assert_equal Digest::SHA256.hexdigest(bytes), artifact['raw_sha256']
        assert_equal 24, artifact['bits_per_pixel']
      end
    end
  end

  def test_distinguishes_jpeg_roundtrip_difference_from_material_colorization
    Dir.mktmpdir do |root|
      path = File.join(root, 'model.skp')
      File.binwrite(path, 'source')
      changed = rgb
      changed.data.setbyte(4, 8)
      texture = Texture.new('embedded.jpg', 2, 1, rgb)
      session = ExactTextureProbe.run(model: Model.new(path, [Material.new('m', texture)]),
        output_root: root, loader: ->(_) { changed })
      entry = JSON.parse(File.read(File.join(session, 'report.json')))['textures'][0]
      assert_equal false, entry['colorization_changes_pixels']
      assert_equal false, entry['jpeg_matches_uncolorized']
      assert_equal false, entry['pixel_identical']
    end
  end
end
