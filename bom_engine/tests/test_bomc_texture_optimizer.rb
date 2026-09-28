# Pure-Ruby tests for evidence-gated BOMC texture staging.

require 'fileutils'
require 'tmpdir'
require_relative '../bomc_texture_optimizer'
require_relative '../material_extractor'

module Sketchup
  class ImageRep
    class << self
      attr_accessor :decoded_candidate
    end

    def self.new(_path)
      decoded_candidate
    end
  end
end

module BOMEngine
  module Constants
    IN_TO_M = 0.0254 unless const_defined?(:IN_TO_M)
  end

  module Traversal
    def self.extract_dicts(_entity)
      {}
    end
  end

  module Logger
    def self.info(_message); end
    def self.warn(_message); end
  end

  module Tests
    module BOMCTextureOptimizerTest
      module_function

      FakeImageRep = Struct.new(:width, :height, :bits_per_pixel, :row_padding, :data) do
        def save_file(path)
          File.open(path, 'wb') { |file| file.write('j' * 1_000) }
          true
        end
      end
      FakeColor = Struct.new(:red, :green, :blue, :alpha)
      FakeMaterial = Struct.new(:object_id, :name, :display_name, :color, :alpha, :materialType, :texture)
      FakeModel = Struct.new(:materials)
      class Cancelled < StandardError; end

      class FakeTexture
        attr_reader :filename, :width, :height, :image_width, :image_height

        def initialize(filename, reference)
          @filename = filename
          @reference = reference
          @width = 10.0
          @height = 10.0
          @image_width = reference.width
          @image_height = reference.height
        end

        def write(path, _colorized)
          bytes = File.extname(path).downcase == '.jpg' ? 1_000 : 10_000
          File.open(path, 'wb') { |file| file.write('x' * bytes) }
          true
        end

        def image_rep(_colorized)
          @reference
        end
      end

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def image_rep(pixels, alpha: nil, row_padding: 0)
        channels = alpha ? 4 : 3
        rows = pixels.each_slice(2).each_with_index.map do |row, row_index|
          bytes = row.each_with_index.flat_map do |rgb, column_index|
            values = rgb.dup
            values << alpha[row_index * 2 + column_index] if alpha
            values
          end
          bytes.pack('C*') + ("\0" * row_padding)
        end
        FakeImageRep.new(2, 2, channels * 8, row_padding, rows.join.b)
      end

      def run
        reference = image_rep([
          [10, 20, 30], [40, 50, 60],
          [70, 80, 90], [100, 110, 120]
        ], row_padding: 2)
        close_candidate = image_rep([
          [11, 20, 30], [40, 51, 60],
          [70, 80, 89], [100, 110, 121]
        ])
        quality = BOMCTextureOptimizer.compare(reference, close_candidate)
        assert(quality[:compatible] && quality[:psnr_db] > 40.0, 'pixel comparison ignores row padding and accepts a high-quality decoded candidate')

        verify_opt_in_lossless_effort_search(reference)

        transparent = image_rep([
          [10, 20, 30], [40, 50, 60],
          [70, 80, 90], [100, 110, 120]
        ], alpha: [255, 255, 127, 255])
        assert(!BOMCTextureOptimizer.opaque?(transparent), 'a texture with any non-opaque alpha is ineligible for JPEG')

        directory = Dir.mktmpdir('bomc-texture-optimizer')
        begin
          staged_path = File.join(directory, 'fallback.png')
          candidate_path = File.join(directory, 'candidate.jpg')
          File.open(staged_path, 'wb') { |file| file.write('p' * 10_000) }
          File.open(candidate_path, 'wb') { |file| file.write('j' * 1_000) }

          selected = BOMCTextureOptimizer.select(
            staged_path: staged_path,
            candidate_path: candidate_path,
            reference: reference,
            candidate: close_candidate,
            native_jpeg: false
          )
          assert(selected[:path] == candidate_path && selected[:selected] == :jpeg_candidate, 'smaller opaque JPEG is selected only after decoded quality passes')
          assert(selected[:savings_bytes] == 9_000 && selected[:quality][:psnr_db] > 40.0, 'selection records byte and quality evidence')

          degraded = image_rep(Array.new(4) { [220, 220, 220] })
          rejected = BOMCTextureOptimizer.select(
            staged_path: staged_path,
            candidate_path: candidate_path,
            reference: reference,
            candidate: degraded,
            native_jpeg: false
          )
          assert(rejected[:path] == staged_path && rejected[:reason] == :quality_gate_failed, 'visibly degraded JPEG falls back to lossless PNG')

          alpha_rejected = BOMCTextureOptimizer.select(
            staged_path: staged_path,
            candidate_path: candidate_path,
            reference: transparent,
            candidate: close_candidate,
            native_jpeg: true
          )
          assert(alpha_rejected[:path] == staged_path && alpha_rejected[:reason] == :alpha_requires_lossless, 'native JPEG hint never overrides transparency preservation')
        ensure
          FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
        end

        default_extraction_dir = Dir.mktmpdir('default-material-extraction')
        extraction_dir = Dir.mktmpdir('bomc-material-extraction')
        begin
          Sketchup::ImageRep.decoded_candidate = close_candidate
          texture = FakeTexture.new('embedded/wood.jpg', reference)
          material = FakeMaterial.new(123, 'Wood', 'Wood', FakeColor.new(255, 255, 255, 255), 1.0, 1, texture)
          legacy = MaterialExtractor.extract(FakeModel.new([material]), nil, default_extraction_dir)
          assert(legacy.fetch(0).dig(:texture, :filename) == 'Wood.png', 'non-BOMC material extraction keeps its existing lossless PNG behavior')
          extracted = MaterialExtractor.extract(FakeModel.new([material]), nil, extraction_dir, optimize_textures: true)
          staged = extracted.fetch(0).fetch(:texture)
          assert(staged[:filename] == 'Wood.jpg', 'material extraction stages an unavailable embedded JPEG in its compact native format')
          assert(staged.dig(:staging_evidence, :selected) == :jpeg_candidate, 'material extraction carries the optimizer quality and byte evidence forward')

          cancelled = false
          begin
            cancellation = lambda do |**event|
              raise Cancelled, 'stop' if event[:stage] == :snapshot_textures
            end
            MaterialExtractor.extract(FakeModel.new([material]), nil, extraction_dir, checkpoint: cancellation, optimize_textures: true)
          rescue Cancelled
            cancelled = true
          end
          assert(cancelled, 'texture staging never swallows cooperative export cancellation')
        ensure
          FileUtils.remove_entry(default_extraction_dir) if default_extraction_dir && Dir.exist?(default_extraction_dir)
          FileUtils.remove_entry(extraction_dir) if extraction_dir && Dir.exist?(extraction_dir)
        end

        lossless_dir = Dir.mktmpdir('lossless-texture-staging')
        begin
          Sketchup::ImageRep.decoded_candidate = close_candidate
          texture = FakeTexture.new('embedded/wood.jpg', reference)
          lossless_result = BOMCTextureOptimizer.stage(
            texture: texture,
            directory: lossless_dir,
            basename: 'Wood',
            source_path: 'embedded/wood.jpg',
            policy: :pixel_lossless
          )
          assert(lossless_result[:path].end_with?('.png'), 'pixel_lossless policy produces PNG')
          assert(lossless_result.dig(:evidence, :selected) == :staged_png, 'pixel_lossless policy selects staged PNG')
          assert(Array(lossless_result.dig(:evidence, :attempts)).any? { |attempt| attempt[:reason] == :native_jpeg_pixel_mismatch }, 'pixel_lossless policy rejects the changed native JPEG pixels')
          assert(lossless_result.dig(:evidence, :quality, :max_channel_error) == 0, 'PNG fallback evidence describes zero-error selected pixels')
        ensure
          FileUtils.remove_entry(lossless_dir) if lossless_dir && Dir.exist?(lossless_dir)
        end

        assert(BOMCTextureOptimizer.native_jpeg_path?('embedded/wood.JPEG'), 'embedded JPEG filename is recognized without requiring a readable source file')
        assert(!BOMCTextureOptimizer.native_jpeg_path?('embedded/glass.png'), 'PNG source does not receive native-JPEG tolerance')

        # Semantic class strictest resolver
        assert(BOMEngine::BOMCTexturePolicy.strictest_semantic_class([:class_c, :class_a, :class_b]) == :class_a, 'strictest class resolves to Class A')
        assert(BOMEngine::BOMCTexturePolicy.strictest_semantic_class([:class_c, :class_b]) == :class_b, 'strictest class resolves to Class B')
        assert(BOMEngine::BOMCTexturePolicy.strictest_semantic_class([:class_c]) == :class_c, 'strictest class resolves to Class C')

        # Quality gate PSNR thresholds
        assert(BOMEngine::BOMCTexturePolicy.min_psnr(profile: :research, semantic_class: :class_c) == 42.0, 'research min PSNR is 42 dB')
        assert(BOMEngine::BOMCTexturePolicy.min_psnr(profile: :visual, semantic_class: :class_a) == 40.0, 'visual class A min PSNR is 40 dB')
        assert(BOMEngine::BOMCTexturePolicy.min_psnr(profile: :visual, semantic_class: :class_b) == 38.0, 'visual class B min PSNR is 38 dB')
        assert(BOMEngine::BOMCTexturePolicy.min_psnr(profile: :visual, semantic_class: :class_c) == 35.0, 'visual class C min PSNR is 35 dB')

        puts 'BOMC Texture Optimizer Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "BOMC Texture Optimizer Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(8)
        false
      end

      def verify_opt_in_lossless_effort_search(reference)
        encoder = BOMCTextureEncoder
        original_capabilities = encoder.method(:capabilities)
        original_encode = encoder.method(:encode_webp)
        original_decode = encoder.method(:decode_webp)
        calls = []
        encoder.define_singleton_method(:capabilities) do |**_options|
          { available: true, verified: true, sha256: 'a' * 64, binary_path: 'bundled-cwebp' }
        end
        encoder.define_singleton_method(:encode_webp) do |source_path:, output_path:, quality:, lossless:, **options|
          calls << { quality: quality, lossless: lossless, options: options }
          size = options[:lossless_method] == 6 ? 800 : 900
          File.binwrite(output_path, 'w' * size)
          { success: true, path: output_path, bytes: size }
        end
        encoder.define_singleton_method(:decode_webp) do |source_path:, output_path:, **_options|
          File.binwrite(output_path, 'decoded png')
          { success: true, path: output_path }
        end

        directory = Dir.mktmpdir('exact-lossless-effort-test')
        begin
          png = File.join(directory, 'source.png')
          File.binwrite(png, 'p' * 10_000)
          texture = FakeTexture.new('source.png', reference)
          result = BOMCTextureOptimizer.stage(
            texture: texture, directory: directory, basename: 'source', source_path: 'source.png',
            profile: :exact, policy: :pixel_lossless, allow_jpeg_color_map: true,
            image_rep_loader: ->(_path) { reference }
          )
          assert(calls.length == 2, 'the size candidate opt-in tries both bounded lossless settings')
          assert(calls[0][:options][:lossless_method] == 4 && calls[0][:options][:lossless_quality] == 75 &&
            calls[0][:options][:multithreaded] == false, 'the default exact lossless trial records explicit m4/q75 settings')
          assert(calls[1][:options][:lossless_method] == 6 && calls[1][:options][:lossless_quality] == 100 &&
            calls[1][:options][:multithreaded] == true, 'the opt-in higher-effort lossless trial uses m6/q100/multithreaded')
          assert(result[:path].include?('lossless-m6-q100-mt.webp'), 'the smaller measured high-effort candidate wins by bytes')
        ensure
          FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
          encoder.define_singleton_method(:capabilities, original_capabilities)
          encoder.define_singleton_method(:encode_webp, original_encode)
          encoder.define_singleton_method(:decode_webp, original_decode)
        end
      end
    end
  end
end

exit(BOMEngine::Tests::BOMCTextureOptimizerTest.run ? 0 : 1)
