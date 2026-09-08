# Run with standalone Ruby:
#   ruby bom_engine/tests/test_decode_budget.rb

require_relative '../decode_budget'
require_relative '../bomc_format'
require_relative '../bomc_decoder'

module BOMEngine
  module Tests
    module DecodeBudgetTest
      module_function

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def assert_raises(message, expected_text)
        error = nil
        begin
          yield
        rescue StandardError => caught
          error = caught
        end
        assert(!error.nil?, message)
        assert(error.message.include?(expected_text), "#{message} reports #{expected_text.inspect}; got #{error.message.inspect}")
        error
      end

      def test_budget_limits_constants
        assert(DecodeBudget::MAX_INPUT_BYTES == 80 * 1024 * 1024, 'MAX_INPUT_BYTES is 80 MiB')
        assert(DecodeBudget::MAX_EXPANDED_BYTES == 120 * 1024 * 1024, 'MAX_EXPANDED_BYTES is 120 MiB')
        assert(DecodeBudget::MAX_ALLOCATION_BYTES == 256 * 1024 * 1024, 'MAX_ALLOCATION_BYTES is 256 MiB')
        assert(DecodeBudget::MAX_SECTIONS == 64, 'MAX_SECTIONS is 64')
      end

      def test_checked_table_bytes_valid
        bytes = DecodeBudget.checked_table_bytes(100, 3, 4, 1200)
        assert(bytes == 1200, 'calculates byte size correctly')
      end

      def test_checked_table_bytes_allocation_overflow
        assert_raises('rejects count exceeding allocation budget', 'exceeds allocation budget') do
          DecodeBudget.checked_table_bytes(0xffff_ffff, 3, 4)
        end
      end

      def test_checked_table_bytes_insufficient_payload
        assert_raises('rejects count when available payload is smaller than min required', 'requires at least 1200 payload bytes, but only 50 bytes are available') do
          DecodeBudget.checked_table_bytes(100, 3, 4, 50)
        end
      end

      def test_checked_table_bytes_negative_and_zero_handling
        assert_raises('rejects negative count', 'table count must be non-negative') do
          DecodeBudget.checked_table_bytes(-1, 3, 4)
        end
        assert_raises('rejects non-positive components', 'components must be positive') do
          DecodeBudget.checked_table_bytes(10, 0, 4)
        end
        assert_raises('rejects non-positive element_bytes', 'element_bytes must be positive') do
          DecodeBudget.checked_table_bytes(10, 3, 0)
        end
        assert(DecodeBudget.checked_table_bytes(0, 3, 4, 0) == 0, 'zero count is valid and requires 0 bytes')
      end

      def test_container_section_count_budget
        sections = [
          { type: BOMC::SECTION_STRINGS, count: 1, bytes: 'abc'.b, compress: false }
        ]
        bytes = BOMC::Container.pack(sections, flags: BOMC::PROFILE_PRODUCTION)
        # Offset 20 is section_count (uint32)
        corrupted = bytes.dup
        corrupted[20, 4] = [65].pack('V')
        assert_raises('rejects container with > 64 sections', 'section count 65 exceeds limit of 64') do
          BOMC::Container.read_directory(corrupted)
        end
      end

      def test_container_raw_size_budget
        sections = [
          { type: BOMC::SECTION_STRINGS, count: 1, bytes: 'abc'.b, compress: false }
        ]
        bytes = BOMC::Container.pack(sections, flags: BOMC::PROFILE_PRODUCTION)
        # In compact directory (24 bytes per entry, starts at offset 32):
        # type(2), codec(1), flags(1), offset(4), stored_size(4), raw_size(4) -> raw_size is at offset 32 + 12 = 44
        corrupted = bytes.dup
        corrupted[44, 4] = [150 * 1024 * 1024].pack('V')
        assert_raises('rejects section raw size exceeding budget', 'exceeds budget of 125829120 bytes') do
          BOMC::Container.read_directory(corrupted)
        end
      end

      class TestDecoderStub
        include BOMCDecoder
      end

      def test_decoder_position_block_f08_rejection
        # 60-byte position block: version 1, codec 2 (FLOAT32), count = 0xffff_ffff, payload_length = 0
        header = [1, 2, 0, 0, 0xffff_ffff, 0].pack('CCCCVV') + [0.0, 0.0, 0.0].pack('E*') + [1.0, 1.0, 1.0].pack('E*')
        assert(header.bytesize == 60, 'header is 60 bytes')

        # Decoder is private class inside BOMCDecoder, we can allocate instance without calling decode
        decoder = BOMCDecoder::Decoder.allocate
        assert_raises('rejects 60-byte position block with count = 0xffff_ffff', 'exceeds allocation budget') do
          decoder.send(:decode_position_block, header)
        end
      end

      def test_decoder_codec_section_budget_overflow
        decoder = BOMCDecoder::Decoder.allocate

        # Normal section header with count = 0xffff_ffff
        normal_header = [1, 1, 0, 0, 0xffff_ffff, 0].pack('CCCCVV')
        assert_raises('rejects normal section count exceeding budget', 'exceeds allocation budget') do
          decoder.send(:decode_codec_section, normal_header, BOMC::NormalCodec)
        end

        # Transform section header with count = 0xffff_ffff
        transform_header = [1, 5, 0, 0, 0xffff_ffff, 0].pack('CCCCVV')
        assert_raises('rejects transform section count exceeding budget', 'exceeds allocation budget') do
          decoder.send(:decode_codec_section, transform_header, BOMC::TransformCodec)
        end
      end

      def run
        test_budget_limits_constants
        test_checked_table_bytes_valid
        test_checked_table_bytes_allocation_overflow
        test_checked_table_bytes_insufficient_payload
        test_checked_table_bytes_negative_and_zero_handling
        test_container_section_count_budget
        test_container_raw_size_budget
        test_decoder_position_block_f08_rejection
        test_decoder_codec_section_budget_overflow
        puts 'Decode Budget Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "Decode Budget Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(12)
        false
      end
    end
  end
end

exit(BOMEngine::Tests::DecodeBudgetTest.run ? 0 : 1) if $PROGRAM_NAME == __FILE__
