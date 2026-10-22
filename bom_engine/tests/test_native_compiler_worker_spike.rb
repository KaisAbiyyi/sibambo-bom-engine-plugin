# frozen_string_literal: true

require 'test/unit'
require 'timeout'
require 'tmpdir'
require_relative '../../tools/performance/native_compiler_worker_spike'

class TestNativeCompilerWorkerSpike < Test::Unit::TestCase
  Spike = SibamboNativeCompilerWorkerSpike

  def setup
    omit 'Native worker spike uses Windows DLL APIs; requires Windows native qualification' unless Gem.win_platform?
    Spike.build_worker!
    @zlib = Spike.zlib_path
    assert(@zlib && File.file?(@zlib), 'zlib DLL is available for the bounded native spike')
  end

  def small_input
    numbers = Array.new(2_048) { |index| (index - 1_024) / 37.0 }
    sections = [
      { type: 1, bytes: ('canonical-json:' + ('abcdef0123456789' * 4_096)).b },
      { type: 7, bytes: ('bomc-section:' + ('xyz9876543210' * 4_096)).b }
    ]
    [numbers, sections]
  end

  def test_worker_matches_ruby_semantics_and_internal_readback
    numbers, sections = small_input
    ruby = Spike.ruby_compile(numbers: numbers, sections: sections)
    Dir.mktmpdir('native-worker-semantics') do |dir|
      input = File.join(dir, 'input.bin')
      output = File.join(dir, 'output.bin')
      Spike.write_payload(input, job_id: 101, numbers: numbers, sections: sections)
      client = Spike::WorkerClient.new(zlib: @zlib)
      begin
        result = client.request(job_id: 101, input_path: input, output_path: output)
        assert_equal :success, result[:status]
        assert_equal ruby[:semantic_sha256], result[:semantic_sha256]
        assert_equal [1, 2, 3, 4], result[:progress].map { |row| row[:stage] }.uniq
        decoded = Spike.read_output(output)
        assert_equal ruby[:semantic_sha256], decoded[:semantic_sha256]
        assert_equal numbers.length, decoded[:numeric_count]
        assert_equal sections.map { |section| Digest::SHA256.hexdigest(section[:bytes]) }, decoded[:sections].map { |section| section[:sha256] }
      ensure
        client.shutdown
      end
      assert_equal false, client.alive?, 'owned worker is reaped after successful completion'
    end
  end

  def test_protocol_version_and_corrupt_payload_fail_closed
    client = Spike::WorkerClient.new(zlib: @zlib)
    begin
      client.send_raw(message_type: Spike::MSG_REQUEST, job_id: 201, version: 99)
      frame = Timeout.timeout(5) { client.next_frame }
      assert_equal Spike::MSG_ERROR, frame[:type]
      assert_match(/version 99 is unsupported/, frame[:payload])
    ensure
      client.shutdown
    end

    Dir.mktmpdir('native-worker-corrupt') do |dir|
      input = File.join(dir, 'bad.bin')
      output = File.join(dir, 'output.bin')
      File.binwrite(input, 'WRONG-PAYLOAD')
      client = Spike::WorkerClient.new(zlib: @zlib)
      begin
        result = client.request(job_id: 202, input_path: input, output_path: output)
        assert_equal :error, result[:status]
        assert_match(/magic mismatch/, result[:error])
        assert_equal false, File.exist?(output)
        assert_equal false, File.exist?("#{output}.part")
      ensure
        client.shutdown
      end
    end
  end

  def test_cancel_is_job_scoped_and_leaves_no_partial_output
    numbers = Array.new(65_536) { |index| index / 19.0 }
    section = ('cancel-me-' + ('0123456789abcdef' * 65_536)).b
    sections = Array.new(24) { |index| { type: index + 1, bytes: section } }
    Dir.mktmpdir('native-worker-cancel') do |dir|
      input = File.join(dir, 'input.bin')
      output = File.join(dir, 'output.bin')
      Spike.write_payload(input, job_id: 301, numbers: numbers, sections: sections)
      client = Spike::WorkerClient.new(zlib: @zlib)
      begin
        cancelled = false
        result = Timeout.timeout(15) do
          client.request(job_id: 301, input_path: input, output_path: output) do |progress|
            if !cancelled && progress[:stage] == 3 && progress[:completed] >= 1
              cancelled = true
              client.cancel(301)
            end
          end
        end
        assert_equal :cancelled, result[:status]
        assert_equal false, File.exist?(output)
        assert_equal false, File.exist?("#{output}.part")
      ensure
        client.shutdown
      end
      assert_equal false, client.alive?, 'cancelled worker is reaped by its owner'
    end
  end

  def test_crash_is_observable_and_process_is_reaped
    client = Spike::WorkerClient.new(zlib: @zlib)
    status = Timeout.timeout(5) { client.crash_for_test }
    assert_equal 97, status.exitstatus
    assert_equal false, client.alive?, 'crashed worker process is reaped rather than orphaned'
  end
end

