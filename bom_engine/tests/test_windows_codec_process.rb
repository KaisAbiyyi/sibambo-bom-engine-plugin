# frozen_string_literal: true
require 'test/unit'
require 'tmpdir'
require 'json'
require 'rbconfig'
require_relative '../windows_codec_process' if File.file?(File.expand_path('../windows_codec_process.rb', __dir__))

class TestWindowsCodecProcess < Test::Unit::TestCase
  def setup
    omit('Windows process boundary') unless Gem.win_platform?
    assert defined?(BOMEngine::WindowsCodecProcess), 'Native codec runner is missing'
    @runner = BOMEngine::WindowsCodecProcess
  end

  def run_ruby(script, args = [], **options)
    @runner.run([RbConfig.ruby, '-e', script, *args], timeout_sec: 2, **options)
  end

  def test_captures_output_without_ruby_spawn
    original = Process.method(:spawn)
    Process.define_singleton_method(:spawn) { |*| raise 'Embedded Ruby spawn must not be used' }
    Dir.mktmpdir do |dir|
      out, err = File.join(dir, 'out'), File.join(dir, 'err')
      assert_equal 0, run_ruby('STDOUT.write("codec-ok"); STDERR.write("diagnostic")', stdout_path: out, stderr_path: err)
      assert_equal 'codec-ok', File.binread(out)
      assert_equal 'diagnostic', File.binread(err)
    end
  ensure
    Process.define_singleton_method(:spawn, original) if original
  end

  def test_preserves_argument_boundaries_without_shell_interpretation
    args = ['', 'spaces here', 'quote"inside', 'trailing space \\', 'back\\\"quote', '& echo bad | > %PATH%', 'jalan_日本']
    Dir.mktmpdir do |dir|
      out = File.join(dir, 'out')
      assert_equal 0, run_ruby('require "json"; STDOUT.write(JSON.generate(ARGV))', args, stdout_path: out)
      assert_equal args, JSON.parse(File.read(out))
    end
  end

  def test_reports_nonzero_exit_code
    assert_equal 7, run_ruby('exit 7')
  end

  def test_rejects_nul_arguments_before_start
    assert_raise(ArgumentError) { run_ruby('exit', ["bad\0arg"]) }
  end

  def test_rejects_non_executable_shell_scripts
    assert_raise(ArgumentError) { @runner.run(['unsafe.bat'], timeout_sec: 1) }
  end

  def test_timeout_reaps_child
    Dir.mktmpdir do |dir|
      marker = File.join(dir, 'late')
      assert_raise(@runner::TimeoutError) do
        @runner.run([RbConfig.ruby, '-e', 'sleep 0.6; File.write(ARGV[0], "bad")', marker], timeout_sec: 0.15)
      end
      sleep 0.7
      assert !File.exist?(marker), 'timed-out child must not remain alive'
    end
  end

  def test_checkpoint_cancellation_reaps_child
    Dir.mktmpdir do |dir|
      marker = File.join(dir, 'late')
      assert_raise(@runner::CancelledError) do
        run_ruby('sleep 0.6; File.write(ARGV[0], "bad")', [marker], checkpoint: -> { raise 'cancel' })
      end
      sleep 0.7
      assert !File.exist?(marker), 'cancelled child must not remain alive'
    end
  end

  def test_missing_executable_fails_with_windows_error
    error = assert_raise(@runner::ProcessError) { @runner.run(['C:/absent/no-codec.exe'], timeout_sec: 1) }
    assert_match(/CreateProcessW.*\d/, error.message)
  end
end
