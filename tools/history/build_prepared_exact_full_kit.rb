# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'optparse'
require_relative 'build_adaptive_preview_kit'
require_relative '../../bom_engine/bomc_prepared_color_maps'

module PreparedExactFullKitBuilder
  def self.build(output:, offline_report:, browser_report:, source_copy: nil, root: AdaptivePreviewKit::ROOT)
    output = File.expand_path(output).tr('\\', '/')
    root = File.expand_path(root).tr('\\', '/')
    offline_report = File.expand_path(offline_report).tr('\\', '/')
    browser_report = File.expand_path(browser_report).tr('\\', '/')
    raise ArgumentError, 'Capture kit already exists; choose a new directory' if File.exist?(output)
    BOMEngine::BOMCPreparedColorMaps.load(offline_report: offline_report, browser_report: browser_report)
    offline = JSON.parse(File.read(offline_report))
    host_path = File.join(File.dirname(File.dirname(offline_report)), offline.fetch('raw_capture_file'))
    host = JSON.parse(File.read(host_path))
    captured_source_path = File.expand_path(host.fetch('source_path')).tr('\\', '/')
    source_path = File.expand_path(source_copy || captured_source_path).tr('\\', '/')
    source_sha = host.fetch('source_sha256')
    unless File.file?(source_path) && Digest::SHA256.file(source_path).hexdigest == source_sha &&
        File.size(source_path) == host.fetch('source_bytes')
      raise ArgumentError, 'Captured SKP bytes are missing or changed'
    end
    files = AdaptivePreviewKit.runtime_files(root)
    source_tree = AdaptivePreviewKit.inventory_digest(files)
    template = File.join(__dir__, 'prepared_exact_capture.rb')
    tooling_sha = Digest::SHA256.hexdigest(File.binread(__FILE__) + File.binread(template) + File.binread(File.join(__dir__, 'build_adaptive_preview_kit.rb')))
    namespace = "PreparedExact_#{Digest::SHA256.hexdigest(source_tree + tooling_sha)[0, 16]}"
    FileUtils.mkdir_p(output)
    files.each do |relative, sha|
      original = File.join(root, relative)
      data = File.binread(original)
      raise 'Source changed during capture snapshot' unless Digest::SHA256.hexdigest(data) == sha
      target = File.join(output, relative)
      FileUtils.mkdir_p(File.dirname(target))
      data = AdaptivePreviewKit.transform(data.force_encoding('UTF-8'), namespace) if relative.end_with?('.rb')
      File.binwrite(target, data)
    end
    FileUtils.cp(template, File.join(output, 'capture.rb'))
    File.write(File.join(output, 'entry.rb'), <<~RUBY)
      module SibamboHistory
        EVOLUTION_LAB_EMBEDDED = true unless const_defined?(:EVOLUTION_LAB_EMBEDDED, false)
        module #{namespace}; end
      end
      require_relative 'capture'
      SibamboExactPreparedCapture.configure(__dir__, SibamboHistory::#{namespace})
    RUBY
    File.write(File.join(output, 'OPERATOR_GUIDE.md'), <<~TEXT)
      # E4 Exact full-model test — release not certified

      Source tree: #{source_tree}
      Tooling: #{tooling_sha}
      Required loader: bomc-next-jcm-v1
      Captured source SHA256: #{source_sha}

      Open the exact saved `#{source_path}` model in SketchUp 2026. Do not edit it.
      Open Extensions > Developer > Ruby Console and run:

      ```ruby
      load #{File.join(output, 'entry.rb').tr('\\', '/').dump}; SibamboExactPreparedCapture.start
      ```

      No extension install or restart is needed. The test creates a new results/capture-*
      directory. It uses the previously browser-verified texture payloads only when the
      current native JPEG and raw displayed pixels match. Other textures use the ordinary
      Exact staging path. The isolated candidate must be smaller than the saved SKP and
      pass the producer's Exact validator. Its status still requires Codex certification.
      This can take time for uncached textures and geometry. Use the dialog's Cancel button
      if needed. Send the results/capture-*/report.json path to Codex after completion.
      The original capture evidence stays at its current path and is never overwritten.
    TEXT
    inventory = Dir.glob(File.join(output, '**', '*')).select { |path| File.file?(path) }.sort.map do |path|
      [path.delete_prefix(output + '/'), Digest::SHA256.file(path).hexdigest]
    end.to_h
    manifest = {'schema' => 'prepared-exact-full-kit-v1', 'status' => 'prepared_pending_runtime', 'ready' => false,
      'source_tree_sha256' => source_tree, 'tooling_sha256' => tooling_sha, 'namespace' => namespace,
      'required_loader' => 'bomc-next-jcm-v1', 'source_files' => files, 'files' => inventory,
      'evidence' => {'offline_report' => offline_report, 'offline_report_sha256' => Digest::SHA256.file(offline_report).hexdigest,
        'browser_report' => browser_report, 'browser_report_sha256' => Digest::SHA256.file(browser_report).hexdigest,
        'captured_source_path' => captured_source_path, 'source_path' => source_path, 'source_sha256' => source_sha}}
    File.write(File.join(output, 'manifest.json'), JSON.pretty_generate(manifest))
    manifest
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {}
  OptionParser.new do |parser|
    parser.on('--output PATH') { |value| options[:output] = value }
    parser.on('--offline-report PATH') { |value| options[:offline_report] = value }
    parser.on('--browser-report PATH') { |value| options[:browser_report] = value }
    parser.on('--source-copy PATH') { |value| options[:source_copy] = value }
  end.parse!
  report = PreparedExactFullKitBuilder.build(**options)
  puts JSON.pretty_generate(report.slice('source_tree_sha256', 'tooling_sha256', 'status', 'ready'))
end
