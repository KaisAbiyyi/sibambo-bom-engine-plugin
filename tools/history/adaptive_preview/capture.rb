# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'
require 'time'
require 'tmpdir'
require 'zlib'

# This module is renamed per build. Runtime evidence is intentionally a separate
# preview schema: it cannot masquerade as an unchanged certified producer SHA.
module AdaptivePreviewCapture
  PROFILES = %w[visual research exact].freeze

  # Raw diagnostics may include infinite PSNR for identical pixels. Preserve it
  # explicitly as text, never as invalid JSON or a fabricated finite metric.
  def self.json_safe_diagnostics(value)
    case value
    when Hash then value.transform_values { |item| json_safe_diagnostics(item) }
    when Array then value.map { |item| json_safe_diagnostics(item) }
    when Float then value.finite? ? value : "nonfinite:#{value}"
    else value
    end
  end

  def self.reserve_session(root)
    FileUtils.mkdir_p(root)
    path = File.join(root, "capture-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}")
    Dir.mkdir(path)
    path
  end

  def self.with_candidate_cache
    Dir.mktmpdir('bomc-candidates') do |directory|
      yield({ directory: directory, entries: {}, hits: 0, jpeg_quality: {}, jpeg_quality_hits: 0 })
    end
  end

  def self.error_details(error)
    result = { 'class' => error.class.name, 'message' => error.message, 'backtrace' => Array(error.backtrace).first(12) }
    %i[texture_diagnostics source_bytes best_candidate_bytes delta_bytes hard_budget_bytes dominant_sections attempts].each do |key|
      result[key.to_s] = error.public_send(key) if error.respond_to?(key)
    end
    json_safe_diagnostics(result)
  end

  # The compact BOMC intentionally omits SketchUp persistent IDs. Capture this
  # separate, hash-bound index while the producer graph still has them; it is
  # evidence for an independent source comparison, never release content.
  def self.write_source_correspondence(path, graph, source_sha256:, bomc_sha256:)
    sha = /\A[0-9a-f]{64}\z/
    raise 'Invalid correspondence hashes' unless sha.match?(source_sha256.to_s) && sha.match?(bomc_sha256.to_s)
    source_id = ->(row) { row.dig(:source_identity, :persistent_id)&.to_s }
    definitions = graph.fetch(:definitions)
    definition_indices = definitions.each_with_index.each_with_object({}) do |(row, index), indices|
      indices[row.fetch(:id)] = index
    end
    raise 'Duplicate graph definition ID' unless definition_indices.length == definitions.length
    unique_ids = lambda do |rows, label|
      ids = rows.map { |row| row['source_id'] }.compact
      raise "Duplicate or missing #{label} source ID" if ids.uniq.length != ids.length
    end
    definition_rows = definitions.each_with_index.map do |row, index|
      root = row[:kind].to_s == 'root'
      id = root ? 'root' : source_id.call(row)
      raise 'Missing definition source ID' if id.nil? || id.empty?
      { 'index' => index, 'source_id' => id, 'kind' => row.fetch(:kind).to_s }
    end
    instance_rows = graph.fetch(:nodes).each_with_index.map do |row, index|
      root = row[:kind].to_s == 'root'
      id = root ? nil : source_id.call(row)
      raise 'Missing instance source ID' if !root && (id.nil? || id.empty?)
      { 'index' => index, 'source_id' => id, 'kind' => row.fetch(:kind).to_s }
    end
    face_rows = graph.fetch(:meshes).each_with_index.flat_map do |mesh, mesh_index|
      definition_index = definition_indices.fetch(mesh.fetch(:definition_id))
      Array(mesh[:faces]).each_with_index.map do |face, face_index|
        id = source_id.call(face)
        raise 'Missing face source ID' if id.nil? || id.empty?
        { 'mesh' => mesh_index, 'face' => face_index,
          'definition' => definition_index, 'source_id' => id }
      end
    end
    unique_ids.call(definition_rows, 'definition')
    unique_ids.call(instance_rows, 'instance')
    unique_ids.call(face_rows, 'face')
    rows = {
      'schema' => 'bomc-source-correspondence-v1', 'ready' => false,
      'source_sha256' => source_sha256, 'bomc_sha256' => bomc_sha256,
      'definitions' => definition_rows, 'instances' => instance_rows, 'faces' => face_rows
    }
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(JSON.generate(rows)) }
    { 'path' => path, 'sha256' => Digest::SHA256.file(path).hexdigest,
      'schema' => rows.fetch('schema') }
  end

  def self.validate_model!(model, source)
    raise 'Open the saved capture model first.' unless model && File.file?(model.path.to_s)
    raise 'Save/review unsaved changes before capture; source must match its pin.' if model.modified?
    raise "Wrong model. Open #{source['path']}" unless File.realpath(model.path).casecmp?(File.realpath(source.fetch('path')))
    raise 'Source file changed; do not overwrite the original pin.' unless Digest::SHA256.file(model.path).hexdigest == source.fetch('sha256')
    true
  end

  # Read just the small encoding contract; do not decode a large model a second
  # time on SketchUp's UI thread after the exporter has already validated it.
  def self.read_contract(path)
    File.open(path, 'rb') do |io|
      header = io.read(32)
      raise 'Truncated BOMC header' unless header && header.bytesize == 32
      magic, _major, _minor, _endian, flags, count, offset = header.unpack('a8vvVVVQ<')
      raise 'Invalid BOMC magic' unless magic == "BOMC\r\n\x1a\n".b
      compact = (flags & 0x10) != 0
      width = compact ? 24 : 40
      raise 'Invalid BOMC directory' unless count <= 1024 && offset + count * width <= io.size
      io.seek(offset)
      entries = io.read(count * width)
      contract = nil
      count.times do |i|
        type, codec, _flags, pos, stored, raw = entries.byteslice(i * width, width).unpack(compact ? 'vCCVVVVV' : 'vCCQ<Q<Q<VVV')
        next unless type == 20
        raise 'Duplicate BOMC encoding contract' if contract
        raise 'Invalid encoding contract section' unless raw == 76 && stored <= 4096 && pos + stored <= io.size && [0, 1].include?(codec)
        io.seek(pos)
        bytes = io.read(stored)
        bytes = Zlib::Inflate.inflate(bytes) if codec == 1
        raise 'Invalid encoding contract length' unless bytes.bytesize == 76
        values = bytes.unpack('vCCQ<EEQ<EEEECCCCV')
        raise 'Unknown contract schema' unless values[0] == 1
        contract = { 'profile' => { 1 => 'exact', 2 => 'research', 3 => 'visual' }[values[1]], 'encoder_revision' => values[-1] }
      end
      return contract if contract
    end
    raise 'Encoding contract missing'
  end

  def self.export_profile(engine, model, profile, session, identity, checkpoint, jcm_matrix: false, prepared_color_maps: nil, candidate_cache: nil, processing: nil)
    profile = profile.to_s
    raise 'Unknown profile' unless PROFILES.include?(profile)
    path = File.join(session, "#{profile}.bomc")
    metadata = File.join(session, "capture_#{profile}.json")
    raise 'Capture already exists; reserve a new session.' if File.exist?(path) || File.exist?(metadata)
    record = identity.merge('schema_version' => 'adaptive-preview-runtime-v1', 'ready' => false,
      'profile' => profile, 'export_status' => 'failed', 'real_runtime_evidence' => false,
      'source_model_path' => model.path, 'source_model_bytes' => File.size(model.path),
      'source_model_sha256' => Digest::SHA256.file(model.path).hexdigest,
      'timestamp' => Time.now.utc.iso8601, 'ruby_version' => RUBY_DESCRIPTION,
      'sketchup_version' => (Sketchup.version if defined?(Sketchup)), 'output_bomc_path' => path)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stages = {}; last_stage = nil; stage_started = started; diagnostics = {}
    begin
      progress = lambda do |event|
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stage = event[:stage].to_s
        if stage != last_stage
          stages[last_stage] = stages.fetch(last_stage, 0) + (now - stage_started) * 1000 if last_stage
          last_stage = stage; stage_started = now
        end
        checkpoint.call(event.merge(profile: profile))
      end
      export_options = {output_path: path, profile: profile.to_sym, progress: progress, diagnostics: diagnostics}
      export_options[:settings] = processing if processing
      export_options[:candidate_cache] = candidate_cache if candidate_cache
      if jcm_matrix
        export_options[:allow_jpeg_color_map] = profile == 'exact'
        export_options[:prepared_color_maps] = prepared_color_maps if profile == 'exact' && prepared_color_maps
      end
      result = engine::BOMCExtension.export(model, **export_options)
      if jcm_matrix && profile == 'exact'
        raise 'Exact export did not declare the JCM loader' unless result.is_a?(Hash) && result[:required_loader] == identity['loader_id'] && result[:required_loader] == 'bomc-next-jcm-v1'
        record['actual_required_loader'] = result[:required_loader]
      end
      checkpoint.call(stage: 'VERIFY_CAPTURE', processed: 0)
      raise 'Source changed during export' unless Digest::SHA256.file(model.path).hexdigest == record['source_model_sha256']
      contract = read_contract(path)
      raise 'Exported contract does not match request' unless contract['profile'] == profile && contract['encoder_revision'] == identity.fetch('profile_contract_revision')
      bomc_sha256 = Digest::SHA256.file(path).hexdigest
      correspondence = if profile == 'exact'
        graph = diagnostics[:graph]
        raise 'Exact export did not expose source correspondence' unless graph
        write_source_correspondence(File.join(session, 'source-correspondence-exact.json'), graph,
          source_sha256: record['source_model_sha256'], bomc_sha256: bomc_sha256)
      end
      record.merge!('actual_contract' => contract, 'bomc_bytes' => File.size(path), 'bomc_sha256' => bomc_sha256,
                    'source_correspondence' => correspondence,
                    'export_status' => 'success', 'real_runtime_evidence' => true)
    rescue StandardError => error
      record['error'] = error_details(error)
    ensure
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stages[last_stage] = stages.fetch(last_stage, 0) + (now - stage_started) * 1000 if last_stage
      record['timings'] = { 'total_wall_clock_ms' => (now - started) * 1000, 'stage_timings_ms' => stages }
      record['texture_diagnostics'] = json_safe_diagnostics(Array(diagnostics.dig(:graph, :materials)).map do |material|
        evidence = material.dig(:texture, :encoding_evidence, :staging)
        { 'material' => material[:name], 'staging' => evidence } if evidence
      end.compact)
      diagnostics.clear
      File.write(metadata, JSON.pretty_generate(record))
    end
    record
  end

  def self.verify_identity!(root, engine, installed_root)
    manifest = JSON.parse(File.read(File.join(root, 'manifest.json')))
    raise 'Preview identity mismatch' unless manifest['source_tree_sha256'] == engine::SOURCE_TREE_SHA256 && manifest['preview_build_sha256'] == engine::PREVIEW_BUILD_SHA256
    expected_loader = manifest['jcm_matrix'] == true ? 'bomc-next-jcm-v1' : 'bomc-next-v1'
    raise 'Preview loader identity mismatch' unless manifest['loader_id'] == expected_loader
    if (prepared = manifest['prepared_maps'])
      raise 'Prepared maps require JCM mode' unless manifest['jcm_matrix'] == true
      {'offline_report' => 'offline_report_sha256', 'browser_report' => 'browser_report_sha256'}.each do |path_key, sha_key|
        path = prepared.fetch(path_key)
        raise "Prepared report changed: #{path_key}" unless File.file?(path) && Digest::SHA256.file(path).hexdigest == prepared.fetch(sha_key)
      end
      unless manifest.fetch('jobs').any? { |job| job.dig('source', 'sha256') == prepared.fetch('source_sha256') }
        raise 'Prepared maps do not match a pinned source'
      end
    end
    plugins = File.dirname(installed_root)
    manifest.fetch('installed_files').each do |relative, sha|
      path = File.expand_path(relative, plugins)
      raise 'Invalid installed-file path' unless path.start_with?(plugins.tr('\\', '/') + '/')
      raise "Installed file changed: #{relative}" unless File.file?(path) && Digest::SHA256.file(path).hexdigest == sha
    end
    raise 'Preview archive changed' unless Digest::SHA256.file(File.join(root, manifest.fetch('package'))).hexdigest == manifest.fetch('package_sha256')
    engine.load_engine
    actual = engine::BOMCExtension.method(:export).source_location.fetch(0)
    expected = File.join(installed_root, 'bom_engine/bomc_extension.rb')
    raise 'Mixed exporter loaded; restart SketchUp.' unless File.expand_path(actual).casecmp?(File.expand_path(expected))
    manifest
  end

  def self.prepared_for_job(manifest, item, engine)
    return nil unless manifest['jcm_matrix'] == true && (prepared = manifest['prepared_maps'])
    return nil unless item.dig('source', 'sha256') == prepared.fetch('source_sha256')
    prepared_module = File.join(__dir__, 'bom_engine/bomc_prepared_color_maps.rb')
    prepared_module = File.expand_path('../../../bom_engine/bomc_prepared_color_maps.rb', __dir__) unless File.file?(prepared_module)
    require prepared_module
    engine::BOMCPreparedColorMaps.load(offline_report: prepared.fetch('offline_report'),
      browser_report: prepared.fetch('browser_report'))
  end

  def self.smoke_passed?(root, manifest)
    tiny = manifest.fetch('jobs').find { |j| j['category'] == 'tiny' }
    Dir.glob(File.join(root, 'results', tiny.fetch('id'), 'capture-*', 'session-status.json')).any? do |status_path|
      begin
        status = JSON.parse(File.read(status_path))
        next false unless status['status'] == 'captured_pending_certification' && status['preview_build_sha256'] == manifest['preview_build_sha256']
        PROFILES.all? do |profile|
          record = JSON.parse(File.read(File.join(File.dirname(status_path), "capture_#{profile}.json")))
          path = File.join(File.dirname(status_path), "#{profile}.bomc")
          record['export_status'] == 'success' && record['preview_build_sha256'] == manifest['preview_build_sha256'] &&
            record['source_model_sha256'] == tiny.dig('source', 'sha256') && Digest::SHA256.file(path).hexdigest == record['bomc_sha256'] &&
          read_contract(path) == { 'profile' => profile, 'encoder_revision' => manifest['profile_contract_revision'] } &&
            (manifest['jcm_matrix'] != true || profile != 'exact' || record['actual_required_loader'] == manifest['loader_id'])
        end
      rescue StandardError
        false
      end
    end
  end

  def self.start(root, engine, installed_root, item, batch_mode: 'auto', batch_size: nil)
    manifest = verify_identity!(root, engine, installed_root)
    raise 'Run 1-tiny successfully on this preview first.' unless item['category'] == 'tiny' || smoke_passed?(root, manifest)
    model = Sketchup.active_model
    validate_model!(model, item.fetch('source'))
    raise 'Another preview export is running.' if engine::ConversionJob.active&.running?
    processing = engine::BOMCProcessing.from_ui(batch_mode: batch_mode, batch_size: batch_size)
    prepared = prepared_for_job(manifest, item, engine)
    session = reserve_session(File.join(root, 'results', item.fetch('id')))
    identity = manifest.slice('producer_base_sha', 'source_tree_sha256', 'preview_build_sha256', 'package_sha256', 'profile_contract_revision', 'loader_id')
    job = engine::ConversionJob.start(title: "Adaptive PREVIEW — #{File.basename(model.path)} [#{manifest['source_tree_sha256'][0, 12]}]", output_path: session, batch_size: processing[:max_items], kind: :capture) do |progress|
      records = {}; reference = nil; cache_metrics = nil
      begin
        checkpoint = lambda do |event|
          raise 'Model changed during capture' unless Sketchup.active_model.equal?(model) && !model.modified?
          progress.call(event)
        end
        run_preflight!(engine, File.join(session, 'codec-preflight.json'), checkpoint: checkpoint)
        require_relative 'native_reference'
        reference = SibamboNativeReference.capture(model, File.join(session, 'native-reference.jsonl'), source: item.fetch('source'), sketchup_version: Sketchup.version, checkpoint: checkpoint)
        with_candidate_cache do |candidate_cache|
          begin
            PROFILES.each do |profile|
              validate_model!(model, item.fetch('source'))
              records[profile] = export_profile(engine, model, profile, session, identity, checkpoint,
                jcm_matrix: manifest['jcm_matrix'] == true, prepared_color_maps: prepared,
                candidate_cache: candidate_cache, processing: processing)
              raise "#{profile} failed. Diagnostic report saved; earlier outputs preserved." unless records[profile]['export_status'] == 'success'
            end
          ensure
            cache_metrics = { 'webp_encode_cache_hits' => candidate_cache[:hits],
              'webp_quality_cache_hits' => candidate_cache.fetch(:quality_hits, 0),
              'jpeg_quality_cache_hits' => candidate_cache.fetch(:jpeg_quality_hits, 0),
              'stored_variants' => candidate_cache[:entries].length }
          end
        end
        validate_model!(model, item.fetch('source'))
        state = identity.merge('status' => 'captured_pending_certification', 'ready' => false, 'source' => item['source'], 'reference' => reference, 'profiles' => records, 'candidate_cache' => cache_metrics)
        File.write(File.join(session, 'session-status.json'), JSON.pretty_generate(state))
        { path: session, source_info: { path: model.path, bytes: item.dig('source', 'bytes') || File.size(model.path) },
          profiles: records.transform_values { |record| { bytes: record.fetch('bomc_bytes') } },
          status: 'captured_pending_certification' }
      rescue StandardError => error
        state = identity.merge('status' => 'failed_or_cancelled', 'ready' => false, 'source' => item['source'], 'reference' => reference, 'profiles' => records, 'candidate_cache' => cache_metrics, 'error' => error_details(error))
        File.write(File.join(session, 'session-status.json'), JSON.pretty_generate(state))
        raise
      end
    end
    job
  end

  def self.run_preflight!(engine, report_path, checkpoint: nil)
    raise 'Preflight report already exists.' if File.exist?(report_path)
    result = begin
      engine::BOMCTextureEncoder.preflight(checkpoint: checkpoint)
    rescue StandardError => error
      { success: false, error: error_details(error) }
    end
    report = result.merge(ready: false, scope: 'codec preflight only; not model or fidelity certification',
      sketchup_version: (Sketchup.version if defined?(Sketchup)), ruby_version: RUBY_DESCRIPTION,
      timestamp: Time.now.utc.iso8601)
    report[:source_tree_sha256] = engine::SOURCE_TREE_SHA256 if engine.const_defined?(:SOURCE_TREE_SHA256, false)
    report[:preview_build_sha256] = engine::PREVIEW_BUILD_SHA256 if engine.const_defined?(:PREVIEW_BUILD_SHA256, false)
    File.write(report_path, JSON.pretty_generate(json_safe_diagnostics(report)))
    raise "Codec preflight failed before model export. See #{report_path}" unless result[:success] == true
    report
  end

  def self.show_options(root, engine, installed_root, item)
    dialog = UI::HtmlDialog.new(
      dialog_title: "Sibambo Preview — #{File.basename(item.fetch('source').fetch('path'))}",
      scrollable: true, resizable: true, width: 620, height: 600,
      min_width: 430, min_height: 420, style: UI::HtmlDialog::STYLE_DIALOG
    )
    dialog.set_file(File.join(installed_root, 'bom_engine', 'ui', 'capture_options.html'))
    dialog.add_action_callback('ready') do |_context|
      dialog.execute_script("initializeCaptureOptions(#{JSON.generate(
        source_name: File.basename(item.fetch('source').fetch('path')),
        build_sha: engine::SOURCE_TREE_SHA256[0, 12]
      )})")
    end
    started = false
    dialog.add_action_callback('start') do |_context, settings_json|
      next if started
      begin
        settings = JSON.parse(settings_json)
        mode = settings.fetch('batch_mode')
        size = settings['batch_size']
        engine::BOMCProcessing.from_ui(batch_mode: mode, batch_size: size)
        started = true
        dialog.close
        start(root, engine, installed_root, item, batch_mode: mode, batch_size: size)
      rescue StandardError => error
        started = false
        UI.messagebox("Capture not started: #{error.message}")
      end
    end
    dialog.add_action_callback('cancel') { |_context| dialog.close }
    dialog.center
    dialog.show
    dialog
  end

  def self.install_menu(root, engine, installed_root)
    return if @menu_installed
    manifest = JSON.parse(File.read(File.join(root, 'manifest.json')))
    display = manifest['jcm_matrix'] == true ? 'Sibambo E4 JCM PREVIEW' : 'Sibambo E4 Adaptive PREVIEW'
    menu = UI.menu('Extensions').add_submenu("#{display} [TREE #{engine::SOURCE_TREE_SHA256[0, 12]}]")
    menu.add_item('0. Check encoder — no model export') do
      begin
        verify_identity!(root, engine, installed_root)
        folder = reserve_session(File.join(root, 'preflight'))
        run_preflight!(engine, File.join(folder, 'codec-preflight.json'))
        UI.messagebox("Codec encode/decode passed in SketchUp.\nReport: #{folder}\nModel size and fidelity are NOT certified.")
      rescue StandardError => error
        UI.messagebox(error.message)
      end
    end
    manifest.fetch('jobs').each do |item|
      menu.add_item("#{item['id']}: #{File.basename(item['source']['path'])} — 3 profiles") do
        begin
          show_options(root, engine, installed_root, item)
        rescue StandardError => error
          UI.messagebox("Capture not started: #{error.message}")
        end
      end
    end
    @menu_installed = true
  end
end
