# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'optparse'
require 'rbconfig'
require_relative 'build_evolution_lab' unless defined?(EvolutionLabBuilder)

# Deliberately not an active release builder. Snapshots current working-tree bytes
# with separate base-commit, source-tree, staged-file and archive identities.
module AdaptivePreviewKit
  ROOT = File.expand_path('../..', __dir__)
  EXCLUDED = %w[tests tools benchmarks graphify-out].freeze

  def self.runtime_files(root)
    Dir.glob(File.join(root, 'bom_engine', '**', '*')).sort.each_with_object({}) do |path, files|
      next unless File.file?(path)
      relative = path.delete_prefix(root.tr('\\', '/') + '/')
      next if (relative.split('/') & EXCLUDED).any? || File.basename(path) == 'BUILD_SHA.txt'
      raise "Symlink not allowed in preview: #{path}" if File.symlink?(path)
      files[relative] = Digest::SHA256.file(path).hexdigest
    end
  end

  def self.inventory_digest(files)
    Digest::SHA256.hexdigest(JSON.generate(files.sort.to_h))
  end

  def self.next_operator_step(jobs)
    small = jobs.find { |job| job['category'] == 'small-textured' }
    medium = jobs.find { |job| job['category'] == 'medium-architectural' }
    steps = []
    steps << if small
               "If tiny succeeds, open saved #{small.fetch('source').fetch('path')} and choose #{small.fetch('id')}."
             else
               'If tiny succeeds, run only another small pinned fixture.'
             end
    if small && medium
      steps << "If that succeeds, open saved #{medium.fetch('source').fetch('path')} and choose #{medium.fetch('id')}."
    end
    steps << 'Stop on the first failure. Send all successful result folders together.'
    steps << 'Do not run texture-heavy or remaining models until this small/medium audit is reviewed.'
    steps.join(' ')
  end

  def self.transform(source, namespace)
    module_count = source.scan(/module\s+BOMEngine\b/).length
    source = source.gsub(/module\s+BOMEngine\b/, "module SibamboHistory\n  module #{namespace}")
    source = source.gsub(/\bBOMEngine::/, "SibamboHistory::#{namespace}::")
    source = source.gsub(/SETTINGS_KEY\s*=\s*["'][^"']+["']/, "SETTINGS_KEY = 'Sibambo_#{namespace}_Settings'")
    source = source.gsub(/Sketchup\.(read|write)_default\(["']BOMEngine_LastSettings["']/,
                         "Sketchup.\\1_default('Sibambo_#{namespace}_Settings'")
    source = source.gsub('unless file_loaded?(__FILE__)', 'unless defined?(SibamboHistory::EVOLUTION_LAB_EMBEDDED) || file_loaded?(__FILE__)')
    source + ("\nend # SibamboHistory\n" * module_count)
  end

  def self.build(output:, matrix_index:, root: ROOT, jcm_matrix: false, prepared_maps: nil)
    output = File.expand_path(output).tr('\\', '/')
    root = File.expand_path(root).tr('\\', '/')
    raise ArgumentError, 'Output already exists; never overwrite a capture kit.' if File.exist?(output)
    raise ArgumentError, 'Unsupported quote in archive path.' if output.include?("'")
    raise ArgumentError, 'JCM mode must be Boolean.' unless jcm_matrix == true || jcm_matrix == false
    raise ArgumentError, 'Prepared maps require JCM mode.' if prepared_maps && !jcm_matrix
    index = JSON.parse(File.read(matrix_index))
    jobs = index.fetch('jobs').map { |j| j.slice('id', 'category', 'fixture_id', 'source') }
    raise 'A tiny smoke fixture is required.' unless jobs.any? { |j| j['category'] == 'tiny' }
    jobs.each do |job|
      raise 'Unsafe job ID' unless job.fetch('id').match?(/\A[a-z0-9-]+\z/)
      source = job.fetch('source')
      raise "Fixture changed: #{source['path']}" unless Digest::SHA256.file(source.fetch('path')).hexdigest == source.fetch('sha256')
      if source.key?('bytes') && (!source['bytes'].is_a?(Integer) || File.size(source.fetch('path')) != source['bytes'])
        raise "Fixture byte count changed: #{source['path']}"
      end
    end
    prepared_identity = nil
    if prepared_maps
      require_relative '../../bom_engine/bomc_prepared_color_maps'
      offline_path = File.expand_path(prepared_maps.fetch(:offline_report)).tr('\\', '/')
      browser_path = File.expand_path(prepared_maps.fetch(:browser_report)).tr('\\', '/')
      BOMEngine::BOMCPreparedColorMaps.load(offline_report: offline_path, browser_report: browser_path)
      offline = JSON.parse(File.read(offline_path))
      host_path = File.join(File.dirname(File.dirname(offline_path)), offline.fetch('raw_capture_file'))
      host = JSON.parse(File.read(host_path))
      source_sha = host.fetch('source_sha256')
      unless jobs.any? { |job| job.dig('source', 'sha256') == source_sha }
        raise ArgumentError, 'Prepared maps do not match a pinned matrix source'
      end
      prepared_identity = {'offline_report' => offline_path,
                           'offline_report_sha256' => Digest::SHA256.file(offline_path).hexdigest,
                           'browser_report' => browser_path,
                           'browser_report_sha256' => Digest::SHA256.file(browser_path).hexdigest,
                           'source_sha256' => source_sha,
                           'source_tree_sha256' => offline.fetch('source_tree_sha256')}
    end
    files = runtime_files(root)
    source_sha = inventory_digest(files)
    support_paths = [__FILE__, File.join(__dir__, 'adaptive_preview/capture.rb'), File.join(__dir__, 'matrix_capture/native_reference.rb'),
                     File.join(__dir__, 'build_evolution_lab.rb')]
    tooling = support_paths.map { |path| [path.delete_prefix(ROOT + '/'), Digest::SHA256.file(path).hexdigest] }.to_h
    build_sha = inventory_digest('source' => source_sha, 'tooling' => inventory_digest(tooling),
      'jcm_matrix' => jcm_matrix, 'prepared_maps' => prepared_identity,
      'jobs' => jobs, 'output' => output)
    namespace = "Adaptive_#{build_sha[0, 16]}"
    folder = "sibambo_e4_#{jcm_matrix ? 'jcm' : 'adaptive'}_#{build_sha[0, 16]}"
    display = jcm_matrix ? 'Sibambo E4 JCM PREVIEW' : 'Sibambo E4 Adaptive PREVIEW'
    stage = File.join(output, 'install', folder)
    FileUtils.mkdir_p(stage)
    files.each do |relative, expected|
      bytes = File.binread(File.join(root, relative))
      raise "Source changed while snapshotting: #{relative}" unless Digest::SHA256.hexdigest(bytes) == expected
      destination = File.join(stage, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      bytes = transform(bytes.force_encoding('UTF-8'), namespace) if relative.end_with?('.rb')
      File.binwrite(destination, bytes)
    end
    File.write(File.join(stage, 'bom_engine/BUILD_SHA.txt'), source_sha)
    branding_path = File.join(stage, 'bom_engine/branding.rb')
    branding = File.read(branding_path).sub("EXTENSION_NAME = 'Sibambo BOMC Engine'", "EXTENSION_NAME = '#{display}'")
    File.write(branding_path, branding)
    html_path = File.join(stage, 'bom_engine/ui/bomc_export_dialog.html')
    html = File.read(html_path).sub('<h1>Sibambo BOMC Engine</h1>', "<h1>#{display}</h1>").sub(' · build <span', ' · source tree <span')
    File.write(html_path, html)
    File.write(File.join(stage, 'capture.rb'), File.read(support_paths[1]).gsub('AdaptivePreviewCapture', "#{namespace}Capture").gsub('SibamboNativeReference', "#{namespace}NativeReference"))
    File.write(File.join(stage, 'native_reference.rb'), File.read(support_paths[2]).gsub('SibamboNativeReference', "#{namespace}NativeReference"))
    File.write(File.join(stage, 'entry.rb'), <<~RUBY)
      require 'sketchup.rb'
      module SibamboHistory
        EVOLUTION_LAB_EMBEDDED = true unless const_defined?(:EVOLUTION_LAB_EMBEDDED, false)
        module #{namespace}
          SOURCE_TREE_SHA256 = #{source_sha.inspect}.freeze
          PREVIEW_BUILD_SHA256 = #{build_sha.inspect}.freeze
          def self.load_engine
            require_relative 'bom_engine/core'
            self
          end
        end
      end
      require_relative 'capture'
      #{namespace}Capture.install_menu(#{output.inspect}, SibamboHistory::#{namespace}, __dir__)
    RUBY
    File.write(File.join(output, 'install', folder + '.rb'), <<~RUBY)
      require 'sketchup.rb'
      require 'extensions.rb'
      unless file_loaded?(__FILE__)
        extension = SketchupExtension.new('#{display} [TREE #{source_sha[0, 12]}]', '#{folder}/entry')
        extension.description = 'Isolated candidate test build. Not certified. Source tree #{source_sha}; preview #{build_sha}.'
        extension.version = '1.2.0'
        extension.creator = 'Sibambo'
        Sketchup.register_extension(extension, true)
        file_loaded(__FILE__)
      end
    RUBY
    Dir.glob(File.join(output, 'install', '**', '*.rb')).each do |path|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-c', path)
      raise "Syntax failure #{path}: #{stdout} #{stderr}" unless status.success?
    end
    installed_files = Dir.glob(File.join(output, 'install', '**', '*')).select { |p| File.file?(p) }.sort.map do |path|
      [path.delete_prefix(File.join(output, 'install') + '/'), Digest::SHA256.file(path).hexdigest]
    end.to_h
    package = File.join(output, folder + '.rbz')
    EvolutionLabBuilder.zip_folder(File.join(output, 'install'), package)
    base, status = Open3.capture2('git', '-C', root, 'rev-parse', 'HEAD')
    raise 'Cannot determine producer base commit' unless status.success?
    dirty, status = Open3.capture2('git', '-C', root, 'status', '--porcelain')
    raise 'Cannot inspect working tree' unless status.success?
    manifest = {
      'schema_version' => 'adaptive-preview-kit-v1', 'ready' => false, 'provisional' => true,
      'status' => 'prepared_pending_runtime', 'producer_base_sha' => base.strip,
      'producer_dirty_at_preparation' => !dirty.empty?, 'source_tree_sha256' => source_sha,
      'preview_build_sha256' => build_sha, 'namespace' => namespace, 'folder' => folder,
      'loader_id' => jcm_matrix ? 'bomc-next-jcm-v1' : 'bomc-next-v1',
      'jcm_matrix' => jcm_matrix, 'prepared_maps' => prepared_identity,
      'package' => File.basename(package), 'package_sha256' => Digest::SHA256.file(package).hexdigest,
      'source_files' => files, 'tooling_files' => tooling, 'installed_files' => installed_files,
      'profile_contract_revision' => 1, 'jobs' => jobs,
      'matrix_index_sha256' => Digest::SHA256.file(matrix_index).hexdigest,
      'consumer_binding' => index['consumer_binding'],
      'evidence_scope' => 'Preview runtime capture only; no promotion, browser evidence or fidelity certification implied.'
    }
    File.write(File.join(output, 'manifest.json'), JSON.pretty_generate(manifest))
    File.write(File.join(output, 'OPERATOR_GUIDE.md'), <<~TEXT)
      # #{display} — not certified

      Source tree: #{source_sha}
      Preview build: #{build_sha}
      Base commit (NOT the modified-source identity): #{base.strip}
      Loader: #{jcm_matrix ? 'bomc-next-jcm-v1' : 'bomc-next-v1'}
      #{jcm_matrix ? 'Exact uses the JCM capability; Visual/Research remain ordinary BOMC. Prepared maps are only reused for their pinned SKP, after live JPEG and pixel hashes match.' : 'All three profiles use ordinary BOMC.'}

      Install #{File.basename(package)} through Extension Manager if not already installed.
      Restart SketchUp. Use Extensions > #{display} [TREE #{source_sha[0, 12]}].
      First choose 0. Check encoder — no model export. Do not start model capture if this fails.
      For the first pass, keep geometry batch on Auto. Manual 96–8192 changes geometry scheduling, not texture encoding; larger batches may reduce UI responsiveness.
      Open saved #{jobs.first['source']['path']}, choose #{jobs.first['id']}. Wait for all three profiles before changing models.
      #{next_operator_step(jobs)}
      No Ruby Console needed. Never use the old Matrix Capture menu for this preview.

      Each run creates a new results/<job>/capture-* folder. Failure retains diagnostics and earlier outputs.
      Runtime success is not release certification. Old kits and installed candidate are unchanged.
      To roll back, disable only this #{display} extension and restart SketchUp.
      Keep this kit at its original path; the launcher binds to it intentionally.
    TEXT
    manifest
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {}
  OptionParser.new do |parser|
    parser.on('--output PATH') { |v| options[:output] = v }
    parser.on('--matrix-index PATH') { |v| options[:matrix_index] = v }
    parser.on('--jcm-matrix') { options[:jcm_matrix] = true }
    parser.on('--offline-report PATH') { |v| (options[:prepared_maps] ||= {})[:offline_report] = v }
    parser.on('--browser-report PATH') { |v| (options[:prepared_maps] ||= {})[:browser_report] = v }
  end.parse!
  result = AdaptivePreviewKit.build(**options)
  puts JSON.pretty_generate(result.slice('source_tree_sha256', 'preview_build_sha256', 'package_sha256', 'status', 'ready'))
end
