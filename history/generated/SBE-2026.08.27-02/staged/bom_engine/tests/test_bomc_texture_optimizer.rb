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

module SibamboHistory
  module V20260827_02
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

        assert(BOMCTextureOptimizer.native_jpeg_path?('embedded/wood.JPEG'), 'embedded JPEG filename is recognized without requiring a readable source file')
        assert(!BOMCTextureOptimizer.native_jpeg_path?('embedded/glass.png'), 'PNG source does not receive native-JPEG tolerance')
        puts 'BOMC Texture Optimizer Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "BOMC Texture Optimizer Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(8)
        false
      end
    end
  end
end

exit(SibamboHistory::V20260827_02::Tests::BOMCTextureOptimizerTest.run ? 0 : 1)

end # SibamboHistory
