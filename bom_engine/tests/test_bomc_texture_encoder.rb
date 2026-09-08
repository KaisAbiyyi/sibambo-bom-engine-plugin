# frozen_string_literal: true
# Unit tests for BOMCTextureEncoder Capability Gate (Batch 6)

require 'test/unit'
require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require 'zlib'
require_relative '../bomc_texture_encoder'

class TestBOMCTextureEncoder < Test::Unit::TestCase
  def setup
    @orig_binary = BOMEngine::BOMCTextureEncoder.configured_binary_path
    BOMEngine::BOMCTextureEncoder.configured_binary_path = nil
  end

  def teardown
    BOMEngine::BOMCTextureEncoder.configured_binary_path = @orig_binary
  end

  def test_missing_binary_capability_state
    BOMEngine::BOMCTextureEncoder.configured_binary_path = '/nonexistent/path/to/cwebp'
    caps = BOMEngine::BOMCTextureEncoder.capabilities(force_refresh: true)

    assert_equal false, caps[:available]
    assert_equal false, caps[:webp]
    assert_equal false, caps[:webp_alpha]
    assert_equal 'unavailable', caps[:version]
    assert_equal :binary_not_found, caps[:status]
    assert_nil caps[:binary_path]
  end

  def test_missing_binary_graceful_encode_failure
    BOMEngine::BOMCTextureEncoder.configured_binary_path = '/nonexistent/path/to/cwebp'
    res = BOMEngine::BOMCTextureEncoder.encode_webp(
      source_path: 'fake.png',
      output_path: 'fake.webp'
    )
    assert_equal false, res[:success]
    assert_equal :encoder_unavailable, res[:reason]
  end

  def test_valid_webp_header_check
    Dir.mktmpdir('webp-test') do |dir|
      valid_webp = File.join(dir, 'valid.webp')
      invalid_webp = File.join(dir, 'invalid.webp')

      # Construct 12-byte valid RIFF....WEBP header
      File.open(valid_webp, 'wb') { |f| f.write("RIFF\x20\x00\x00\x00WEBPVP8 ") }
      File.open(invalid_webp, 'wb') { |f| f.write("PNG\x0D\x0A\x1A\x0Axxxxxxxxx") }

      assert BOMEngine::BOMCTextureEncoder.valid_webp_header?(valid_webp)
      assert !BOMEngine::BOMCTextureEncoder.valid_webp_header?(invalid_webp)
    end
  end

  def test_bundled_encoder_is_verified_and_encodes_real_opaque_and_alpha_png
    omit('bundled cwebp.exe integration is Windows-only') unless Gem.win_platform?

    BOMEngine::BOMCTextureEncoder.configured_binary_path = nil
    caps = BOMEngine::BOMCTextureEncoder.capabilities(force_refresh: true)

    assert_equal true, caps[:available]
    assert_equal true, caps[:verified]
    assert_equal :bundled, caps[:source]
    assert_match(/1\.6\.0/, caps[:version])
    assert_equal BOMEngine::BOMCTextureEncoder::BUNDLED_CWEBP_SHA256, caps[:sha256]

    Dir.mktmpdir('real-webp') do |dir|
      opaque_png = File.join(dir, 'opaque.png')
      alpha_png = File.join(dir, 'alpha.png')
      write_rgba_png(opaque_png, [255, 0, 0, 255, 0, 255, 0, 255])
      write_rgba_png(alpha_png, [255, 0, 0, 255, 0, 0, 255, 64])

      opaque = BOMEngine::BOMCTextureEncoder.encode_webp(
        source_path: opaque_png,
        output_path: File.join(dir, 'opaque.webp'),
        lossless: true
      )
      alpha = BOMEngine::BOMCTextureEncoder.encode_webp(
        source_path: alpha_png,
        output_path: File.join(dir, 'alpha.webp'),
        lossless: true
      )

      assert_equal true, opaque[:success]
      assert_equal true, alpha[:success]
      assert BOMEngine::BOMCTextureEncoder.valid_webp_header?(opaque[:path])
      assert BOMEngine::BOMCTextureEncoder.valid_webp_header?(alpha[:path])
    end
  end

  def test_mock_transcoding_lifecycle
    Dir.mktmpdir('mock-encoder') do |dir|
      # Create a mock ruby script that mimics cwebp
      mock_script = File.join(dir, 'mock_cwebp.rb')
      File.open(mock_script, 'w') do |f|
        f.puts <<~RUBY
          if ARGV.include?('-version')
            puts '1.3.2'
            exit 0
          end
          out_idx = ARGV.index('-o')
          if out_idx && ARGV[out_idx + 1]
            out_file = ARGV[out_idx + 1]
            File.open(out_file, 'wb') { |file| file.write("RIFF\\x20\\x00\\x00\\x00WEBPVP8 ") }
            exit 0
          end
          exit 1
        RUBY
      end

      mock_exec = create_mock_executable(dir, 'mock_cwebp', mock_script)

      BOMEngine::BOMCTextureEncoder.configured_binary_path = mock_exec
      caps = BOMEngine::BOMCTextureEncoder.capabilities(force_refresh: true)

      assert_equal true, caps[:available]
      assert_equal '1.3.2', caps[:version]
      assert_equal :ready, caps[:status]

      source_png = File.join(dir, 'test.png')
      target_webp = File.join(dir, 'test.webp')
      File.open(source_png, 'wb') { |f| f.write('dummy-png') }

      result = BOMEngine::BOMCTextureEncoder.encode_webp(
        source_path: source_png,
        output_path: target_webp,
        quality: 85
      )

      assert_equal true, result[:success]
      assert_equal target_webp, result[:path]
      assert File.file?(target_webp)
      assert Dir.glob(File.join(dir, '*.part')).empty?, 'no temp part files remain'
    end
  end

  def test_mock_cancellation_cleans_up
    Dir.mktmpdir('mock-cancel') do |dir|
      mock_script = File.join(dir, 'mock_slow.rb')
      File.open(mock_script, 'w') do |f|
        f.puts <<~RUBY
          if ARGV.include?('-version')
            puts '1.3.2'
            exit 0
          end
          sleep 5
          exit 0
        RUBY
      end

      mock_exec = create_mock_executable(dir, 'mock_slow', mock_script)

      BOMEngine::BOMCTextureEncoder.configured_binary_path = mock_exec
      source_png = File.join(dir, 'test.png')
      target_webp = File.join(dir, 'test.webp')
      File.open(source_png, 'wb') { |f| f.write('dummy-png') }

      cancelled_checkpoint = lambda do |**_event|
        raise StandardError, 'user cancelled export'
      end

      assert_raise(BOMEngine::BOMCTextureEncoder::TranscodeCancelledError) do
        BOMEngine::BOMCTextureEncoder.encode_webp(
          source_path: source_png,
          output_path: target_webp,
          checkpoint: cancelled_checkpoint
        )
      end

      assert Dir.glob(File.join(dir, '*.part')).empty?, 'cancelled transcoding leaves no partial files'
      assert !File.file?(target_webp), 'target file is not created on cancellation'
    end
  end

  def test_external_binary_trust_verification
    Dir.mktmpdir('mock-external') do |dir|
      mock_script = File.join(dir, 'mock_cwebp.rb')
      File.open(mock_script, 'w') do |f|
        f.puts <<~RUBY
          if ARGV.include?('-version')
            puts '1.4.0'
            exit 0
          end
        RUBY
      end
      mock_exe = create_mock_executable(dir, 'cwebp', mock_script)
      actual_sha = Digest::SHA256.file(mock_exe).hexdigest

      BOMEngine::BOMCTextureEncoder.configured_binary_path = mock_exe

      # 1. Without trusted SHA set, external binary is unverified
      caps = BOMEngine::BOMCTextureEncoder.capabilities(force_refresh: true)
      assert_equal true, caps[:available]
      assert_equal false, caps[:verified]
      assert_equal :configured, caps[:source]
      assert_equal :ready, caps[:status]

      # 2. With matching trusted SHA, external binary is verified
      BOMEngine::BOMCTextureEncoder.trusted_external_sha256 = actual_sha
      caps = BOMEngine::BOMCTextureEncoder.capabilities(force_refresh: true)
      assert_equal true, caps[:available]
      assert_equal true, caps[:verified]
      assert_equal :ready, caps[:status]

      # 3. With mismatched trusted SHA, external binary fails trust verification and is unavailable
      BOMEngine::BOMCTextureEncoder.trusted_external_sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
      caps = BOMEngine::BOMCTextureEncoder.capabilities(force_refresh: true)
      assert_equal false, caps[:available]
      assert_equal false, caps[:verified]
      assert_equal :external_trust_verification_failed, caps[:status]

      BOMEngine::BOMCTextureEncoder.trusted_external_sha256 = nil
    end
  end


  private

  def create_mock_executable(dir, name, ruby_script)
    if Gem.win_platform?
      path = File.join(dir, "#{name}.bat")
      File.write(path, "@\"#{RbConfig.ruby}\" \"#{ruby_script}\" %*\n")
    else
      path = File.join(dir, name)
      File.write(path, "#!/bin/sh\nexec \"#{RbConfig.ruby}\" \"#{ruby_script}\" \"$@\"\n")
      FileUtils.chmod(0o755, path)
    end
    path
  end

  def write_rgba_png(path, pixels)
    width = 2
    height = 1
    raw = "\x00".b + pixels.pack('C*')
    signature = "\x89PNG\r\n\x1a\n".b
    ihdr = [width, height, 8, 6, 0, 0, 0].pack('NNC5')
    File.binwrite(path, signature + png_chunk('IHDR', ihdr) + png_chunk('IDAT', Zlib::Deflate.deflate(raw)) + png_chunk('IEND', ''.b))
  end

  def png_chunk(type, data)
    payload = type.b + data
    [data.bytesize].pack('N') + payload + [Zlib.crc32(payload)].pack('N')
  end
end
