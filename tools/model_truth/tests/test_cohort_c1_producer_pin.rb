# frozen_string_literal: true

# SIB-R1 cohort C1 verifier (plan SIB-R1-ITCON-001-COHORT-C1 v1.0, C-D4).
# This branch must accept only the C1 producer P-C1 and refuse the
# historical D4 producer pin. It is never merged into any branch.

require 'test/unit'
require 'digest'
require 'json'
require 'fileutils'
require_relative '../bomc_side'
require_relative 'support/fixture'
require_relative 'support/harness'

class TestCohortC1ProducerPin < Test::Unit::TestCase
  BS = SibamboModelTruthV1::BomcSide
  CANDIDATE = '7448f3e67bd24a37f1619f625991b3304347094cd13cf5c003a347097f9ac3de'
  HISTORICAL = '3f2d314a3a0147ce56914537ef98fd0b77068bb680bcb0000f4b554d44f523a1'

  def setup
    @root = TestTmp.dir('pin')
    @dwebp = File.join(@root, 'dwebp.exe')
    @ffmpeg = File.join(@root, 'ffmpeg.exe')
    [@dwebp, @ffmpeg].each { |path| File.binwrite(path, 'tool') }
    @bomc = File.join(@root, 'candidate.bomc')
    File.binwrite(@bomc, 'not a real bomc')
    pins = { @dwebp => BS::DWEBP_SHA256, @ffmpeg => BS::FFMPEG_SHA256 }
    @original_sha_file = BS.method(:sha_file)
    original = @original_sha_file
    BS.define_singleton_method(:sha_file) { |path| pins.fetch(path) { original.call(path) } }
  end

  def teardown
    original = @original_sha_file
    BS.define_singleton_method(:sha_file) { |path| original.call(path) }
  end

  def corpus_row(pin)
    row = MTFixture.corpus_row('c' * 64)
    row['exact'] = row['exact'].merge('path' => @bomc, 'sha256' => Digest::SHA256.file(@bomc).hexdigest,
                                      'producerSourceSha256' => pin, 'sourceSha256' => 'c' * 64)
    row
  end

  def capture(pin, name)
    BS.capture(corpus_row: corpus_row(pin), run_dir: File.join(@root, name, '20261120T000000Z'),
               dwebp_path: @dwebp, ffmpeg_path: @ffmpeg)
  rescue StandardError => error
    error
  end

  def test_pin_is_the_candidate_runtime_only
    assert_equal CANDIDATE, BS::PRODUCER_PIN
    refute_equal HISTORICAL, BS::PRODUCER_PIN
  end

  def test_historical_producer_bomc_is_refused
    error = capture(HISTORICAL, 'historical')
    assert_kind_of StandardError, error
    assert_match(/producer pin mismatch/, error.message)
  end

  def test_candidate_producer_bomc_passes_the_pin_gate
    error = capture(CANDIDATE, 'candidate')
    # The placeholder bytes are not a BOMC, so decoding must fail after the pin gate.
    assert_kind_of StandardError, error
    assert_no_match(/producer pin mismatch|input sha256 mismatch|source sha mismatch|tool_pin_mismatch/, error.message)
  end
end
