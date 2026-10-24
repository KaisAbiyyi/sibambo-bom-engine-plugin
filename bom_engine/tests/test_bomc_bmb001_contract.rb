# frozen_string_literal: true
# BMB-001: independently authored, synthetic-only binary-container regression.
# Run: ruby bom_engine/tests/test_bomc_bmb001_contract.rb
#
# Exercises the existing producer's in-memory BOMC container implementation.
# Does not use or serialize real SketchUp/source-house fixtures.

require 'digest'
require_relative '../bomc_format'

module BOMEngine
  module Tests
    module BMB001BinaryContract
      module_function

      def check(message)
        raise "FAIL: #{message}" unless yield
        puts "PASS: #{message}"
      end

      def rejects(message, expected)
        begin
          yield
        rescue StandardError => error
          check(message) { error.message.include?(expected) }
          return
        end
        raise "FAIL: #{message} (no exception)"
      end

      def run
        # Section 241 is a synthetic opaque unknown-section payload at the
        # container layer, not a claim about the Editor's authoring schema.
        sections = [
          { type: 241, count: 1, bytes: 'synthetic-unrecognized-section'.b, compress: false },
          { type: BOMC::SECTION_STRINGS, count: 4, bytes: ('synthetic-text-' * 200).b, compress: true }
        ]
        packed = BOMC::Container.pack(sections, flags: BOMC::PROFILE_PRODUCTION)
        parsed = BOMC::Container.parse(packed)
        header = parsed.fetch(:header)
        rows = parsed.fetch(:sections)
        check('BOMC magic is the pinned eight-byte marker') { packed.byteslice(0, 8) == "BOMC\r\n\x1a\n".b }
        check('default container version is 1.2') { header[:major] == 1 && header[:minor] == 2 }
        check('fixed header and compact directory widths match') { header[:header_bytes] == 32 && header[:directory_entry_bytes] == 24 }
        check('compact directory flag and little-endian marker are valid') { (header[:flags] & BOMC::FLAG_COMPACT_DIRECTORY) != 0 && header[:endianness] == :little }
        check('sections are sorted by ID, including opaque section 241') { rows.map { |row| row[:type] } == [BOMC::SECTION_STRINGS, 241] }
        check('section payloads are 8-byte aligned') { rows.all? { |row| (row[:offset] % 8).zero? } }
        check('DEFLATE and STORE are distinguished from geometry codecs') { rows.map { |row| row[:codec] } == [BOMC::CODEC_DEFLATE, BOMC::CODEC_STORE] }
        check('DEFLATE decodes stored bytes correctly') { rows[0][:bytes] == ('synthetic-text-' * 200).b }
        check('opaque unknown section survives at the container level') { rows[1][:bytes] == 'synthetic-unrecognized-section'.b }
        check('same synthetic sections generate identical SHA256') { Digest::SHA256.hexdigest(packed) == Digest::SHA256.hexdigest(BOMC::Container.pack(sections, flags: BOMC::PROFILE_PRODUCTION)) }

        legacy = BOMC::Container.pack(sections, compact_directory: false, version_minor: 0)
        legacy_header = BOMC::Container.parse(legacy)[:header]
        check('legacy 1.0 uses 40-byte directory and remains readable') { legacy_header[:major] == 1 && legacy_header[:minor] == 0 && legacy_header[:directory_entry_bytes] == 40 }

        bad_crc = packed.dup
        bad_crc.setbyte(rows[1][:offset], bad_crc.getbyte(rows[1][:offset]) ^ 0x01)
        rejects('stored-byte checksum mutation is rejected', 'checksum') { BOMC::Container.parse(bad_crc) }

        bad_minor = packed.dup
        bad_minor[10, 2] = [3].pack('v')
        rejects('future minor 1.3 fails closed', 'unsupported version 1.3') { BOMC::Container.parse(bad_minor) }

        bad_major = packed.dup
        bad_major[8, 2] = [2].pack('v')
        rejects('future major 2.0 fails closed', 'unsupported version 2.2') { BOMC::Container.parse(bad_major) }

        bad_codec = packed.dup
        first_dir_entry = header[:directory_offset]
        bad_codec.setbyte(first_dir_entry + 2, 255)
        rejects('unknown section compression codec fails closed', 'unsupported codec') { BOMC::Container.parse(bad_codec) }

        bad_overlap = packed.dup
        second_dir_entry = first_dir_entry + header[:directory_entry_bytes]
        bad_overlap[second_dir_entry + 4, 4] = [rows[0][:offset]].pack('V')
        rejects('overlapping sections fail closed', 'overlaps') { BOMC::Container.parse(bad_overlap, verify_checksums: false) }

        rejects('truncated header fails closed', 'truncated header') { BOMC::Container.parse(packed.byteslice(0, 31)) }

        puts 'BMB-001 synthetic binary contract: ALL PASSED'
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  BOMEngine::Tests::BMB001BinaryContract.run
end
