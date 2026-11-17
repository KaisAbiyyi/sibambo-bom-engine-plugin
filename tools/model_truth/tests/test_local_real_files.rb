# frozen_string_literal: true

# Local-only checks on the owner's real files. Skipped (reported SKIP with the
# reason) unless env SIB_MT_REAL=1. They read private models and never write
# anything outside D:\projects\sibambo\scratch\r1-model-truth.

require 'test/unit'
require 'json'
require 'fileutils'
require_relative 'support/harness'

class TestLocalRealFiles < Test::Unit::TestCase
  BS = SibamboModelTruthV1::BomcSide
  CORPUS = ENV.fetch('SIB_MT_CORPUS', 'D:/projects/sibambo/docs/paper/SIB-R1-ITCON/inventory/corpus.json')
  WEBP_DIR = ENV.fetch('SIB_MT_WEBP_DIR', 'D:/projects/sibambo/scratch/r1-wp2/webp')
  SHARP = ENV.fetch('SIB_MT_SHARP', 'D:/projects/sibambo/scratch/r1-wp2/webp-eval/sharp_results.json')
  FFMPEG = ENV.fetch('SIB_MT_FFMPEG', 'C:/Users/kaisa/AppData/Local/Microsoft/WinGet/Packages/yt-dlp.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe/ffmpeg-N-125365-g9a01c1cb6a-win64-gpl/bin/ffmpeg.exe')
  DWEBP = File.expand_path('../../../bom_engine/bin/win64/dwebp.exe', __dir__)

  def setup
    omit('SKIP: set SIB_MT_REAL=1 to run the real-file checks') unless ENV['SIB_MT_REAL'] == '1'
  end

  def test_house2_bomc_side_is_deterministic
    row = JSON.parse(File.read(CORPUS))['models'].find { |m| m['model'] == 'house2' }
    root = TestTmp.dir('real-house2')
    m = %w[a b].map do |n|
      BS.capture(corpus_row: row, run_dir: File.join(root, n, 'r'), dwebp_path: DWEBP, ffmpeg_path: FFMPEG)
    end
    assert_equal true, m[0][:complete]
    assert_equal m[0][:files]['definitions.ndjson'], m[1][:files]['definitions.ndjson']
    assert_equal m[0][:items_ndjson_decompressed_sha256], m[1][:items_ndjson_decompressed_sha256]
    assert_equal m[0][:root_digest], m[1][:root_digest]
    assert_equal 1778, m[0][:counts][:faces]
    assert_equal 4350, m[0][:counts][:edges]
    tables = JSON.parse(File.read(File.join(root, 'a', 'r', 'bomc', 'tables.json')))
    assert_equal 0, tables['textures'].count { |t| t['pixel']['status'] == 'FAIL' }
  end

  def test_webp_route_matches_sharp_for_all_e_webp_files
    rows = JSON.parse(File.read(SHARP))['rows']
    assert_equal 59, rows.length
    tmp = TestTmp.dir('real-webp')
    rows.each_with_index do |r, i|
      res = BS.webp_pixels(File.join(WEBP_DIR, r['file']), { index: i, width_px: r['width'], height_px: r['height'] }, DWEBP, FFMPEG, tmp)
      assert_equal 'OK', res[:status], "#{r['file']}: #{res.inspect}"
      assert_equal r['sha_sharp'], res[:sha256], r['file']
    end
  end
end
