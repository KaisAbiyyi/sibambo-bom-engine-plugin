require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'digest'
require 'fileutils'
require_relative '../../tools/history/build_prepared_exact_full_kit' if File.file?(File.expand_path('../../tools/history/build_prepared_exact_full_kit.rb', __dir__))

class PreparedExactFullKitTest < Minitest::Test
  OFFLINE = 'D:/projects/sibambo/scratch/exact-jcm-pixels-20260922-01/results/offline-20260922T131415-9e2eb88a/report.json'
  BROWSER = 'D:/projects/sibambo/scratch/exact-jcm-pixels-20260922-01/results/offline-20260922T131415-9e2eb88a/browser-verification-60HNnv/report.json'
  SOURCE_COPY = File.expand_path('../../../model-eval-old/skps/RUMAH Y.skp', __dir__)

  def test_builder_pins_new_source_and_external_pixel_evidence_without_installation
    skip 'Captured runtime fixture unavailable on this host' unless File.file?(OFFLINE) && File.file?(BROWSER) && File.file?(SOURCE_COPY)
    Dir.mktmpdir do |dir|
      kit = File.join(dir, 'kit')
      manifest = PreparedExactFullKitBuilder.build(output: kit, offline_report: OFFLINE, browser_report: BROWSER, source_copy: SOURCE_COPY)
      assert_equal false, manifest['ready']
      assert_equal 'prepared_pending_runtime', manifest['status']
      assert_equal Digest::SHA256.file(OFFLINE).hexdigest, manifest.dig('evidence', 'offline_report_sha256')
      assert_equal Digest::SHA256.file(BROWSER).hexdigest, manifest.dig('evidence', 'browser_report_sha256')
      assert_equal SOURCE_COPY.tr('\\', '/'), manifest.dig('evidence', 'source_path')
      assert_includes File.read(File.join(kit, 'OPERATOR_GUIDE.md')), SOURCE_COPY.tr('\\', '/')
      assert manifest.fetch('files').key?('bom_engine/bomc_prepared_color_maps.rb')
      assert File.file?(File.join(kit, 'entry.rb'))
      assert File.file?(File.join(kit, 'OPERATOR_GUIDE.md'))
      assert_empty Dir.glob(File.join(kit, '**', '*.rbz'))
      assert_raises(ArgumentError) do
        PreparedExactFullKitBuilder.build(output: kit, offline_report: OFFLINE, browser_report: BROWSER, source_copy: SOURCE_COPY)
      end
      assert_raises(ArgumentError) do
        PreparedExactFullKitBuilder.build(output: File.join(dir, 'wrong-source'), offline_report: OFFLINE,
          browser_report: BROWSER, source_copy: __FILE__)
      end
      refute File.exist?(File.join(dir, 'wrong-source'))
      changed_copy = File.join(dir, 'changed-source.skp')
      FileUtils.cp(SOURCE_COPY, changed_copy)
      File.open(changed_copy, 'r+b') do |file|
        first_byte = file.read(1).ord
        file.rewind
        file.write([first_byte ^ 0xff].pack('C'))
      end
      assert_equal File.size(SOURCE_COPY), File.size(changed_copy)
      assert_raises(ArgumentError) do
        PreparedExactFullKitBuilder.build(output: File.join(dir, 'changed-source-kit'), offline_report: OFFLINE,
          browser_report: BROWSER, source_copy: changed_copy)
      end
      refute File.exist?(File.join(dir, 'changed-source-kit'))

      interpolated_path = File.join(dir, 'kit-#{1+1}')
      PreparedExactFullKitBuilder.build(output: interpolated_path, offline_report: OFFLINE,
        browser_report: BROWSER, source_copy: SOURCE_COPY)
      expected_load = "load #{File.join(interpolated_path, 'entry.rb').tr('\\', '/').dump}; SibamboExactPreparedCapture.start"
      assert_includes File.read(File.join(interpolated_path, 'OPERATOR_GUIDE.md')), expected_load
    end
  end
end
