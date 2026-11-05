require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../bomc_extension'
require_relative '../bomc_png_worker'

class TestBatchTextureCleanup < Minitest::Test
  def test_nested_batch_output_can_run_png_worker_and_clean_export_scratch
    skip 'Windows D-drive cleanup regression' unless Gem.win_platform? && Dir.exist?('D:/')

    # Reproduce an attempt directory deep enough that the former hash-named
    # PNG worker cache record exceeded Windows' 260-character unlink limit.
    Dir.mktmpdir('batch-cleanup-') do |root|
      parent = File.join(root, 'attempt-' + 'a' * [160 - root.length - 9, 1].max)
      FileUtils.mkdir_p(parent)
      output = File.join(parent, 'artifact.bomc')
      File.binwrite(output, 'published artifact must survive scratch cleanup')
      context = BOMEngine::BOMCExtension.send(:export_context, output, nil, profile: :exact)
      texture_directory = nil
      compile = lambda do |_, **options|
        texture_directory = options.fetch(:base_path)
        worker = BOMEngine::BOMCPngWorker
        # Real Windows PowerShell/C# worker: verify the cache is created, the
        # filtered pixels are exact, and the caller's cleanup can delete it.
        assert_equal "\0\1\2\3".b, worker.filter(raw: "\0\1\2\3".b,
          width: 1, height: 1, bpp: 3, directory: texture_directory)
        records = Dir.glob(File.join(texture_directory, '.png-worker-cache', '*.json'))
        assert_equal 1, records.length
        # Standalone mingw Ruby can delete longer paths than SketchUp's
        # embedded Ruby. Enforce the host's legacy MAX_PATH compatibility
        # boundary instead of claiming standalone unlink proves host support.
        assert_operator records.first.encode(Encoding::UTF_16LE).bytesize / 2, :<, 260,
          'worker cache must remain below the host Windows cleanup path limit'
        :compiled
      end
      BOMEngine::BOMCSizeGate.stub(:compile_candidate, compile) do
        assert_equal :compiled, context[:compile].call({}, {}, output, nil)
      end
      context[:cleanup].call
      refute Dir.exist?(texture_directory), 'all export-owned scratch must be removed'
      assert_equal 'published artifact must survive scratch cleanup', File.binread(output)
      # Repeated cleanup is safe, including when unwind runs after a failure.
      context[:cleanup].call
    ensure
      # Keep a failed reproduction isolated on D: without masking its error.
      FileUtils.remove_entry(texture_directory, true) if texture_directory && Dir.exist?(texture_directory)
    end
  end
end
