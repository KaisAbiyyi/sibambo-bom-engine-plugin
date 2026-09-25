# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'digest'
require_relative 'build_evolution_lab'
require_relative 'active_release_catalog'

module T8CaptureKitBuilder
  ROOT_DIR = File.expand_path('../..', __dir__)
  SCRATCH_DIR = File.expand_path('../scratch', ROOT_DIR)
  KIT_DIR = File.join(SCRATCH_DIR, 't8-capture-kit')
  TEMP_GEN_DIR = File.join(KIT_DIR, 'temp_gen')
  TEMP_DIST_DIR = File.join(KIT_DIR, 'temp_dist')
  RESULTS_DIR = File.join(KIT_DIR, 'results')

  E4_RELEASE_ID = 'next-from-8082541'
  PINNED_PRODUCER_SHA = 'bd6782691ef8ba98f9d3baab698bc1cd961ce393'
  BASE_PRODUCER_SHA = '8082541d852cd68b9874231e41c6b9c967c74d26'
  PINNED_CONSUMER_SHA = '4c927dfc4c38dea767ff8f7a3f796230e25c45bf'
  EXPECTED_SNAPSHOT_TREE_SHA256 = '703e65a95b459b852409abab50d53f7044c35f83a40a8ba48496c465786c0e6d'
  EXPECTED_CATALOG_PACKAGE_SHA256 = '1e929b7b552c48cd6e8552f10150c0fc56eab0d99b4b95503ba43b9dafc4fc21'

  def self.build
    puts "======================================================================"
    puts "  SIBAMBO — T8 RUNTIME CAPTURE KIT BUILDER (E4 CANDIDATE)"
    puts "======================================================================"

    catalog_path = File.join(ROOT_DIR, 'history', 'active-releases.json')
    records = EvolutionActiveCatalog.load(path: catalog_path, verify_certifications: false)
    e4_record = records.find { |r| r['id'] == E4_RELEASE_ID }

    raise "E4 release '#{E4_RELEASE_ID}' not found in active catalog" unless e4_record
    unless e4_record['producerSha'] == PINNED_PRODUCER_SHA
      raise "E4 producerSha mismatch: expected #{PINNED_PRODUCER_SHA}, got #{e4_record['producerSha']}"
    end
    unless e4_record['baseProducerSha'] == BASE_PRODUCER_SHA
      raise "E4 baseProducerSha mismatch: expected #{BASE_PRODUCER_SHA}, got #{e4_record['baseProducerSha']}"
    end

    FileUtils.mkdir_p(KIT_DIR)
    FileUtils.mkdir_p(RESULTS_DIR)
    FileUtils.touch(File.join(RESULTS_DIR, '.gitkeep'))

    puts "Building isolated candidate package for #{E4_RELEASE_ID}..."
    built_pkg = EvolutionLabBuilder.build_active(
      candidate: E4_RELEASE_ID,
      dist_dir: TEMP_DIST_DIR,
      generated_dir: TEMP_GEN_DIR
    )

    source_rbz = built_pkg[:rbz_path]
    raise "Built RBZ missing at #{source_rbz}" unless File.file?(source_rbz)

    target_rbz = File.join(KIT_DIR, 'sibambo_bom_engine_next_from_8082541.rbz')
    FileUtils.cp(source_rbz, target_rbz)

    actual_package_sha256 = Digest::SHA256.file(target_rbz).hexdigest
    staged_dir = File.join(TEMP_GEN_DIR, E4_RELEASE_ID, 'staged')
    actual_snapshot_tree_sha256 = EvolutionLabBuilder.compute_tree_sha(staged_dir)

    unless actual_snapshot_tree_sha256 == EXPECTED_SNAPSHOT_TREE_SHA256
      raise "Snapshot tree SHA256 mismatch! Expected #{EXPECTED_SNAPSHOT_TREE_SHA256}, got #{actual_snapshot_tree_sha256}"
    end

    # Staged folder copy for direct loading fallback
    kit_staged_dir = File.join(KIT_DIR, 'staged')
    FileUtils.rm_rf(kit_staged_dir)
    FileUtils.cp_r(staged_dir, kit_staged_dir)

    puts "Staged snapshot tree SHA256 verified: #{actual_snapshot_tree_sha256}"
    puts "Candidate package SHA256:             #{actual_package_sha256}"

    manifest = {
      'schema_version' => 't8-capture-manifest-v1',
      'release_id' => E4_RELEASE_ID,
      'title' => e4_record['title'],
      'state' => e4_record['state'],
      'producer_sha' => PINNED_PRODUCER_SHA,
      'base_producer_sha' => BASE_PRODUCER_SHA,
      'consumer_sha' => PINNED_CONSUMER_SHA,
      'loader_id' => e4_record['loaderId'] || 'bomc-next-v1',
      'profile_contract_revision' => e4_record.fetch('profileContractRevision'),
      'entry_kind' => e4_record['entryKind'] || 'bomc-three-profile',
      'supported_profiles' => e4_record['profiles'] || ['visual', 'research', 'exact'],
      'builder_revision' => '1.0',
      'transformer_revision' => '1.0',
      'snapshot_tree_sha256' => actual_snapshot_tree_sha256,
      'package_sha256' => actual_package_sha256,
      'catalog_package_sha256' => EXPECTED_CATALOG_PACKAGE_SHA256,
      'relative_paths' => {
        'package' => 'sibambo_bom_engine_next_from_8082541.rbz',
        'capture_script' => 'capture_e4.rb',
        'operator_guide' => 'OPERATOR_GUIDE.md',
        'verifier' => 'verify_capture.rb',
        'results_directory' => 'results'
      },
      'created_at' => Time.now.utc.iso8601
    }

    manifest_file = File.join(KIT_DIR, 'manifest.json')
    File.write(manifest_file, JSON.pretty_generate(manifest), encoding: 'UTF-8')
    puts "Wrote capture kit manifest: #{manifest_file}"

    # Generate the capture runner script
    generate_capture_script(KIT_DIR, actual_package_sha256)

    # Generate the operator guide
    generate_operator_guide(KIT_DIR, actual_package_sha256)

    # Generate the verification script
    generate_verifier_script(KIT_DIR)

    # One-click SketchUp menu launcher; operator does not need Ruby Console.
    generate_menu_launcher(KIT_DIR)

    puts "\n======================================================================"
    puts "  T8 CAPTURE KIT READY AT: #{KIT_DIR}"
    puts "======================================================================"
    KIT_DIR
  end

  def self.generate_capture_script(kit_dir, package_sha256)
    script_path = File.join(kit_dir, 'capture_e4.rb')
    code = <<~'RUBY'
      # frozen_string_literal: true
      # SIBAMBO BOM Engine — T8 E4 Runtime Capture Script for SketchUp 2026
      # Safe usage in SketchUp Ruby Console (or the installed menu launcher):
      #   load 'D:/projects/sibambo/scratch/t8-capture-kit/capture_e4.rb'
      #   SibamboCaptureKit.start_interactive

      require 'json'
      require 'time'
      require 'fileutils'
      require 'digest'
      require 'zlib'

      module SibamboCaptureKit
        KIT_DIR = File.expand_path(__dir__)
        MANIFEST_PATH = File.join(KIT_DIR, 'manifest.json')
        RESULTS_DIR = File.join(KIT_DIR, 'results')
        FileUtils.mkdir_p(RESULTS_DIR)

        PROFILES = %i[visual research exact].freeze
        PRODUCER_SHA = 'bd6782691ef8ba98f9d3baab698bc1cd961ce393'.freeze
        RELEASE_ID = 'next-from-8082541'.freeze
        EXPECTED_PROFILE_CONTRACT_REVISION = 1

        EXPECTED_EXPORT_STAGES = %w[
          INITIALIZE SCAN_MODEL SNAPSHOT_MATERIALS SNAPSHOT_TEXTURES
          SNAPSHOT_ENTITIES CLASSIFY BUILD_COVERAGE BUILD_DEFINITIONS
          BUILD_INSTANCES COMPILE_METADATA ENCODE_POSITIONS ENCODE_TOPOLOGY
          ENCODE_NORMALS ENCODE_UV ENCODE_TRANSFORMS ENCODE_TEXTURES
          COMPRESS_SECTIONS WRITE_CONTAINER SIZE_GATE VALIDATE DONE
        ].freeze

        def self.read_bomc_encoding_contract(bomc_path)
          return nil unless File.file?(bomc_path) && File.size(bomc_path) >= 32
          bytes = File.binread(bomc_path)
          return nil if bytes.bytesize < 32
          magic, major, minor, endian, flags, section_count, dir_offset = bytes[0, 32].unpack('a8vvVVVQ<')
          return nil unless magic == "BOMC\r\n\x1a\n".b

          compact = (flags & 0x10) != 0
          entry_bytes = compact ? 24 : 40
          entry_pack = compact ? 'vCCVVVVV' : 'vCCQ<Q<Q<VVV'
          dir_size = section_count * entry_bytes
          return nil if dir_offset + dir_size > bytes.bytesize

          section_count.times do |i|
            entry_raw = bytes.byteslice(dir_offset + i * entry_bytes, entry_bytes)
            vals = entry_raw.unpack(entry_pack)
            sec_type, sec_codec, sec_flags, sec_offset, stored_size, raw_size = vals[0, 6]
            if sec_type == 20 # SECTION_ENCODING_CONTRACT
              return nil if sec_offset + stored_size > bytes.bytesize
              sec_data = bytes.byteslice(sec_offset, stored_size)
              if sec_codec == 1 # DEFLATE
                sec_data = Zlib::Inflate.inflate(sec_data) rescue nil
              end
              return nil unless sec_data && sec_data.bytesize >= 76
              c_vals = sec_data.unpack('vCCQ<EEQ<EEEECCCCV')
              prof_map = { 1 => 'exact', 2 => 'research', 3 => 'visual' }
              return { profile: prof_map[c_vals[1]], encoder_revision: c_vals[-1] } if c_vals[0] == 1
              return nil
            end
          end
          nil
        rescue StandardError
          nil
        end

        def self.read_bomc_encoding_contract_profile(bomc_path)
          read_bomc_encoding_contract(bomc_path)&.dig(:profile)
        end

        def self.verify_engine_identity!(engine)
          manifest = JSON.parse(File.read(MANIFEST_PATH))
          raise 'Unexpected capture manifest identity.' unless manifest['producer_sha'] == PRODUCER_SHA && manifest['release_id'] == RELEASE_ID
          raise 'Loaded E4 commit differs from capture manifest.' unless engine::COMMIT_SHA == PRODUCER_SHA
          root = File.dirname(engine.method(:load_engine).source_location.fetch(0)).tr('\\', '/')
          digest = Digest::SHA256.new
          Dir.glob(File.join(root, '**', '*')).reject { |f| File.directory?(f) || File.basename(f) == 'SNAPSHOT_METADATA.json' }.sort.each do |file|
            digest.update(file.delete_prefix(root + '/'))
            digest.update(Digest::SHA256.file(file).digest)
          end
          raise 'Loaded E4 files differ from the pinned snapshot. Restart SketchUp with the capture kit candidate.' unless digest.hexdigest == manifest['snapshot_tree_sha256']
          package = File.join(KIT_DIR, 'sibambo_bom_engine_next_from_8082541.rbz')
          raise 'Capture package checksum mismatch.' unless Digest::SHA256.file(package).hexdigest == manifest['package_sha256']
          engine.load_engine
          expected_exporter = File.expand_path(File.join(root, 'bom_engine', 'bomc_extension.rb'))
          actual_exporter = File.expand_path(engine::BOMCExtension.method(:export).source_location.fetch(0))
          raise 'Mixed E4 exporter detected. Restart SketchUp.' unless actual_exporter.casecmp?(expected_exporter)
          engine
        end

        def self.ensure_extension_loaded!
          unless defined?(Sketchup)
            raise 'SibamboCaptureKit must be run inside Trimble SketchUp (Sketchup module not found).'
          end

          if defined?(SibamboHistory::Next_from_8082541)
            return verify_engine_identity!(SibamboHistory::Next_from_8082541)
          end

          plugins_dir = Sketchup.find_support_file('Plugins')
          if plugins_dir
            installed_entry = File.join(plugins_dir, 'sibambo_bom_engine_next_from_8082541', 'entry_next_from_8082541.rb')
            if File.file?(installed_entry)
              require installed_entry
              return verify_engine_identity!(SibamboHistory::Next_from_8082541)
            end
          end

          kit_staged_entry = File.join(KIT_DIR, 'staged', 'entry_next_from_8082541.rb')
          if File.file?(kit_staged_entry)
            require kit_staged_entry
            return verify_engine_identity!(SibamboHistory::Next_from_8082541)
          end

          raise "E4 candidate extension is not installed. Please install 'sibambo_bom_engine_next_from_8082541.rbz' via SketchUp Extension Manager first."
        end

        def self.export_profile(profile, output_dir: nil, checkpoint: nil)
          if defined?(Sketchup) && defined?(UI) && checkpoint.nil?
            raise 'Direct capture blocks SketchUp. Use SibamboCaptureKit.start_interactive.'
          end
          ext_mod = ensure_extension_loaded!
          model = Sketchup.active_model

          if model.nil?
            raise 'No active model in SketchUp. Please open a real .skp model first.'
          end
          if model.path.to_s.strip.empty?
            raise 'The active model has not been saved to disk. Please save it as a .skp file first.'
          end
          if model.modified?
            raise 'Save the model (Ctrl+S) before capture so the source hash matches the exported model.'
          end

          prof_sym = profile.to_s.downcase.to_sym
          unless PROFILES.include?(prof_sym)
            raise "Invalid profile: #{profile.inspect}. Expected one of: #{PROFILES.inspect}"
          end

          dest_dir = output_dir ? File.expand_path(output_dir) : RESULTS_DIR
          FileUtils.mkdir_p(dest_dir)

          model_basename = File.basename(model.path, File.extname(model.path))
          output_bomc_path = File.join(dest_dir, "#{model_basename}__E4__#{prof_sym.to_s.upcase}.bomc")
          capture_json_path = File.join(dest_dir, "capture_#{prof_sym}.json")
          if File.exist?(output_bomc_path) || File.exist?(capture_json_path)
            raise "Existing capture preserved in #{dest_dir}. Ask Codex to archive it before retrying."
          end

          puts '======================================================================'
          puts "  SIBAMBO T8 CAPTURE: Exporting Profile '#{prof_sym.to_s.upcase}'"
          puts "  Model:  #{model.path}"
          puts "  Output: #{output_bomc_path}"
          puts '======================================================================'

          manifest = File.file?(MANIFEST_PATH) ? JSON.parse(File.read(MANIFEST_PATH)) : {}
          release_id = manifest['release_id'] || RELEASE_ID
          producer_sha = manifest['producer_sha'] || PRODUCER_SHA
          consumer_sha = manifest['consumer_sha'] || '4c927dfc4c38dea767ff8f7a3f796230e25c45bf'
          loader_id = manifest['loader_id'] || 'bomc-next-v1'
          contract_revision = manifest['profile_contract_revision'] || EXPECTED_PROFILE_CONTRACT_REVISION
          package_sha256 = manifest['package_sha256'] || manifest['catalog_package_sha256']
          snapshot_tree_sha256 = manifest['snapshot_tree_sha256'] || '703e65a95b459b852409abab50d53f7044c35f83a40a8ba48496c465786c0e6d'

          source_model_bytes = (File.size(model.path) rescue nil)
          source_model_sha256 = (File.file?(model.path) ? Digest::SHA256.file(model.path).hexdigest : nil rescue nil)

          stage_timings = {}
          current_stage = nil
          stage_start_time = nil
          export_errors = []

          progress_cb = lambda do |event|
            stage = event[:stage]
            if stage && stage != current_stage
              now = Time.now
              if current_stage && stage_start_time
                elapsed_stage_ms = ((now - stage_start_time) * 1000.0).round(2)
                stage_timings[current_stage.to_s] = {
                  duration_ms: elapsed_stage_ms,
                  processed: event[:processed],
                  total: event[:total]
                }
              end
              current_stage = stage
              stage_start_time = now
            end
            checkpoint.call(event.merge(stage: "#{prof_sym.to_s.upcase}: #{stage}")) if checkpoint
          end

          t0 = Time.now
          mono_t0 = defined?(Process::CLOCK_MONOTONIC) ? Process.clock_gettime(Process::CLOCK_MONOTONIC) : t0.to_f

          begin
            bomc_ext = ext_mod.const_get(:BOMCExtension)
            bomc_ext.export(
              model,
              output_path: output_bomc_path,
              profile: prof_sym,
              progress: progress_cb
            )
          rescue StandardError => e
            if checkpoint && ext_mod.const_defined?(:ConversionJob, false) &&
               e.is_a?(ext_mod.const_get(:ConversionJob).const_get(:Cancelled))
              raise
            end
            export_errors << "#{e.class}: #{e.message}"
            export_errors.concat(e.backtrace.first(10)) if e.backtrace
            puts "  [ERROR] Export failed: #{e.message}"
          end

          t1 = Time.now
          mono_t1 = defined?(Process::CLOCK_MONOTONIC) ? Process.clock_gettime(Process::CLOCK_MONOTONIC) : t1.to_f
          total_wall_clock_ms = ((mono_t1 - mono_t0) * 1000.0).round(2)

          if current_stage && stage_start_time
            stage_timings[current_stage.to_s] = {
              duration_ms: ((t1 - stage_start_time) * 1000.0).round(2)
            }
          end

          observed_stages = stage_timings.keys
          unavailable_stages = EXPECTED_EXPORT_STAGES - observed_stages
          stage_evidence = (unavailable_stages.empty? && !observed_stages.empty?) ? 'complete' : 'incomplete'

          bomc_bytes = File.file?(output_bomc_path) ? File.size(output_bomc_path) : 0
          bomc_sha256 = (File.file?(output_bomc_path) && bomc_bytes > 0) ? Digest::SHA256.file(output_bomc_path).hexdigest : nil
          actual_contract = read_bomc_encoding_contract(output_bomc_path)
          actual_bomc_prof = actual_contract&.dig(:profile)
          actual_bomc_revision = actual_contract&.dig(:encoder_revision)
          export_errors << 'Exported BOMC profile does not match requested profile.' unless actual_bomc_prof == prof_sym.to_s
          export_errors << "Exported BOMC contract revision #{actual_bomc_revision.inspect} does not match manifest revision #{contract_revision}." unless actual_bomc_revision == contract_revision
          unless !model.modified? && Digest::SHA256.file(model.path).hexdigest == source_model_sha256
            export_errors << 'Source model changed during capture; save and capture again.'
          end

          # Strict fail-closed evidence flag: only true when export succeeded, file exists, has nonzero bytes, and SHA calculated
          real_runtime_evidence = export_errors.empty? && File.file?(output_bomc_path) && bomc_bytes > 0 && !bomc_sha256.nil?
          export_status = real_runtime_evidence ? 'success' : 'failed'

          record = {
            'schema_version' => 't8-runtime-capture-v1',
            'release_id' => release_id,
            'producer_sha' => producer_sha,
            'consumer_sha' => consumer_sha,
            'loader_id' => loader_id,
            'profile_contract_revision' => contract_revision,
            'package_sha256' => package_sha256,
            'snapshot_tree_sha256' => snapshot_tree_sha256,
            'profile' => prof_sym.to_s,
            'actual_bomc_profile' => actual_bomc_prof,
            'actual_bomc_revision' => actual_bomc_revision,
            'timestamp' => Time.now.utc.iso8601,
            'source_model_path' => model.path.to_s.gsub('\\', '/'),
            'source_model_bytes' => source_model_bytes,
            'source_model_sha256' => source_model_sha256,
            'output_bomc_path' => output_bomc_path.gsub('\\', '/'),
            'bomc_sha256' => bomc_sha256,
            'bomc_bytes' => bomc_bytes,
            'sketchup_version' => Sketchup.version,
            'ruby_version' => defined?(RUBY_DESCRIPTION) ? RUBY_DESCRIPTION : RUBY_VERSION,
            'real_runtime_evidence' => real_runtime_evidence,
            'export_status' => export_status,
            'export_errors' => export_errors,
            'timings' => {
              'total_wall_clock_ms' => total_wall_clock_ms,
              'stage_timings' => stage_timings,
              'observed_stages' => observed_stages,
              'unavailable_stages' => unavailable_stages,
              'stage_timing_evidence' => stage_evidence
            }
          }

          File.write(capture_json_path, JSON.pretty_generate(record), encoding: 'UTF-8')

          if export_status == 'success'
            puts "  [SUCCESS] Profile '#{prof_sym}' exported in #{total_wall_clock_ms} ms."
            puts "  BOMC file: #{output_bomc_path} (#{bomc_bytes} bytes, SHA256: #{bomc_sha256[0..11]}...)"
            puts "  Section 20 profile: #{actual_bomc_prof}"
            puts "  Capture record: #{capture_json_path}"
          else
            puts "  [FAILED] Profile '#{prof_sym}' failed. See #{capture_json_path} for details."
          end
          puts '======================================================================'

          record
        end

        def self.export_all(output_dir: nil, checkpoint: nil)
          if defined?(Sketchup) && defined?(UI) && checkpoint.nil?
            raise 'Direct capture blocks SketchUp. Use SibamboCaptureKit.start_interactive.'
          end
          results = {}
          PROFILES.each do |prof|
            results[prof] = export_profile(prof, output_dir: output_dir, checkpoint: checkpoint)
            break unless results[prof]['export_status'] == 'success'
          end
          session_file = File.join(output_dir || RESULTS_DIR, 't8_capture_session.json')
          File.write(session_file, JSON.pretty_generate({
            'session_id' => "t8-capture-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}",
            'completed_at' => Time.now.utc.iso8601,
            'profiles' => results
          }), encoding: 'UTF-8')
          successful = results.values.count { |record| record['export_status'] == 'success' }
          puts "\n#{successful}/3 profiles exported successfully. Session record written to: #{session_file}"
          results
        end

        def self.start_interactive
          engine = ensure_extension_loaded!
          model = Sketchup.active_model
          raise 'Open and save RUMAH L.skp before capture.' unless model && File.basename(model.path.to_s).casecmp?('RUMAH L.skp')
          raise 'Save RUMAH L.skp before capture.' if model.modified?
          require File.join(KIT_DIR, 'verify_capture.rb')
          job_class = engine.const_get(:ConversionJob)
          raise 'Another BOMC export is already running.' if job_class.active&.running?
          job = job_class.start(
            title: 'Sibambo E4 — RUMAH L capture (3 profiles)',
            output_path: File.join(RESULTS_DIR, "capture-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}"),
            batch_size: 256
          ) do |progress|
            records = export_all(checkpoint: progress)
            unless records.length == PROFILES.length && records.values.all? { |record| record['export_status'] == 'success' }
              raise 'Capture stopped after a failed profile. Existing results are preserved; inspect the capture record before retrying.'
            end
            {
              path: RESULTS_DIR,
              bytes: records.values.sum { |record| record['bomc_bytes'].to_i },
              profile: 'visual+research+exact',
              status: 'captured_pending_certification'
            }
          end
          timer_id = nil
          timer_id = UI.start_timer(0.5, true) do
            next if job.running?
            UI.stop_timer(timer_id)
            begin
              result = T8CaptureVerifier.verify(nil, skip_consumer_inspection: true)
              count = result.fetch(:verified_captures, {}).length
              UI.messagebox("RUMAH L E4 capture: #{count}/3 verified. Status: #{result[:status]}. Results: #{RESULTS_DIR}. Send this status to Codex; release remains not ready.")
            rescue StandardError => error
              UI.messagebox("Capture verification failed: #{error.class}: #{error.message}. Existing results preserved. Ask Codex before retrying.")
            end
          end
          job
        end
      end
    RUBY
    File.write(script_path, code, encoding: 'UTF-8')
  end

  def self.generate_menu_launcher(kit_dir)
    script_path = File.join(kit_dir, 'sibambo_t7_capture_launcher.rb')
    code = <<~RUBY
      # frozen_string_literal: true
      # Place this file in SketchUp 2026's Plugins directory, then restart SketchUp.
      # It adds one menu command; capture and verification remain pinned to the kit.

      module SibamboT7CaptureLauncher
        KIT_DIR = #{kit_dir.gsub('\\', '/').inspect}.freeze
        CAPTURE_SCRIPT = File.join(KIT_DIR, 'capture_e4.rb').freeze
        VERIFIER_SCRIPT = File.join(KIT_DIR, 'verify_capture.rb').freeze

        def self.run
          model = Sketchup.active_model
          raise 'Open and save RUMAH L.skp before capture.' unless model && File.basename(model.path.to_s).casecmp?('RUMAH L.skp')
          raise 'Capture kit missing. Ask Codex to repair it.' unless File.file?(CAPTURE_SCRIPT) && File.file?(VERIFIER_SCRIPT)

          require CAPTURE_SCRIPT
          SibamboCaptureKit.start_interactive
        rescue StandardError => error
          UI.messagebox("RUMAH L E4 capture failed: \#{error.class}: \#{error.message}. Existing results preserved. Ask Codex before retrying.")
        end
      end

      if defined?(Sketchup) && defined?(UI)
        UI.menu('Extensions').add_item('Sibambo E4 — Capture RUMAH L (3 profiles)') { SibamboT7CaptureLauncher.run }
      end
    RUBY
    File.write(script_path, code, encoding: 'UTF-8')
  end

  def self.generate_operator_guide(kit_dir, package_sha256)
    guide_path = File.join(kit_dir, 'OPERATOR_GUIDE.md')
    content = <<~MARKDOWN
      # SIBAMBO T8 Runtime Capture Kit — Operator Instructions

      **Target Release**: `next-from-8082541` (Candidate E4)  
      **Producer SHA**: `bd6782691ef8ba98f9d3baab698bc1cd961ce393`
      **Consumer Pinned SHA**: `#{PINNED_CONSUMER_SHA}`  
      **Package SHA-256**: `#{package_sha256}`  
      **Kit Path**: `#{kit_dir.gsub('\\', '/')}`  

      > [!IMPORTANT]
      > **Readiness Invariant**: Successful completion of this capture kit produces `captured_pending_certification`, **NOT** release-ready (`ready: false`). Real-runtime certification requires subsequent 5-run browser cold/warm benchmarking and formal release certification.

      ---

      ## Who does what?

      The user opens saved `RUMAH L.skp` in SketchUp and clicks the capture command under Extensions. Ruby Console is not required. Codex handles kit installation, verification, and consumer Git/benchmark work. A dirty consumer checkout makes captures provisional; it does not prevent SketchUp capture. Release readiness stays false until later certification.

      Save with Ctrl+S immediately before capture. Do not edit the model while exporting. Existing results are preserved: ask Codex to archive them before repeating a capture.

      ## Step 1: Pre-Install Verification Gate (Codex)
      Before installing the candidate package or running SketchUp, verify kit integrity from your terminal:

      ```powershell
      ruby #{File.join(kit_dir, 'verify_capture.rb').gsub('\\', '/')}
      ```
      *(or via consumer Bun verifier: `bun D:/projects/sibambo/scratch/t0-worktrees-20260907/consumer/scripts/verify-t8-capture.ts`)*

      - **Expected Pre-Install Result**: `incomplete (ready: false, provisional: true)` with missing profiles `["visual", "research", "exact"]`.
      - The verifier will confirm that `manifest.json`, the RBZ package, and repository provenance are valid and fail-closed.

      ---

      ## Step 2: Open SketchUp 2026 Pro and Open Model
      1. Launch **Trimble SketchUp Pro 2026**.
      2. Open `RUMAH L.skp`.
      3. Verify the model is saved on disk.

      ---

      ## Step 3: Candidate E4 Package
      If Codex has already verified the installed candidate snapshot against this kit, do not reinstall. Otherwise:
      1. In SketchUp, open **Extensions > Extension Manager**.
      2. Click **Install Extension...** at the bottom left.
      3. Select:
         `#{File.join(kit_dir, 'sibambo_bom_engine_next_from_8082541.rbz').gsub('/', '\\')}`
      4. Confirm installation. The extension **"Sibambo BOM Engine — Next Evolution (Candidate from 8082541)"** is now active.

      ---

      ## Step 4: Run Captures from Extensions Menu (Recommended)
      Codex installs `sibambo_t7_capture_launcher.rb` into SketchUp's Plugins folder. Restart SketchUp after launcher installation. Open the saved `RUMAH L.skp`, then click **Extensions > Sibambo E4 — Capture RUMAH L (3 profiles)** once. A cooperative progress dialog runs the three exports; keep it open, do not edit the model, and do not repeat the command. Cancel is supported. Existing results are preserved, not overwritten.

      If the menu launcher is unavailable, Ruby Console remains a fallback. Open **Window > Ruby Console** if exposed by your SketchUp install, then use `SibamboCaptureKit.start_interactive` after loading the script. Never call `export_all` or `export_profile` directly from Ruby Console: they are synchronous internal methods and block SketchUp.

      ### Safe Ruby Console fallback
      ```ruby
      load '#{File.join(kit_dir, 'capture_e4.rb').gsub('\\', '/')}'; SibamboCaptureKit.start_interactive
      ```

      ---

      ## Step 5: Post-Capture Verification Gate
      After running the captures in SketchUp, verify the generated evidence:

      ```powershell
      ruby #{File.join(kit_dir, 'verify_capture.rb').gsub('\\', '/')}
      ```
      *(or via consumer Bun verifier: `bun D:/projects/sibambo/scratch/t0-worktrees-20260907/consumer/scripts/verify-t8-capture.ts`)*

      - **Expected Post-Capture Result**: `captured_pending_certification (ready: false)` (or `blocked` if consumer checkout is dirty).
      - The verifier validates:
        1. All 3 BOMC output files exist with matching SHA-256 digests and non-zero bytes.
        2. Actual BOMC Section 20 encoding contract matches the profile identity.
        3. Source model SHA-256 and package tuple are consistent across all 3 profiles.
        4. Real-runtime evidence flag is true and export errors array is empty.

      ---

      ## Step 6: Uninstall / Rollback Package
      When done with capture:
      1. Open **Extensions > Extension Manager**.
      2. Find **Sibambo BOM Engine — Next Evolution (Candidate from 8082541)**.
      3. Click **Uninstall** (or toggle **Disabled**).
      4. Restart SketchUp after disabling/uninstalling to clear the loaded candidate.

      ---

      ## Step 7: Report Completion to Codex / Antigravity
      Notify the assistant with this message:
      > **"T8 runtime capture finished. Output generated in D:/projects/sibambo/scratch/t8-capture-kit/results/"**
    MARKDOWN
    File.write(guide_path, content, encoding: 'UTF-8')
  end

  def self.generate_verifier_script(kit_dir)
    verifier_path = File.join(kit_dir, 'verify_capture.rb')
    code = <<~'RUBY'
      # frozen_string_literal: true
      # SIBAMBO T8 Runtime Capture Verifier
      # Validates manifest, capture JSON schema, file existence, SHA256 digests, Section 20 profile identity,
      # path traversal safety, cross-profile consistency, and consumer repository provenance.

      require 'json'
      require 'digest'
      require 'fileutils'
      require 'zlib'
      require 'open3'
      require 'time'

      module T8CaptureVerifier
        KIT_DIR = File.expand_path(__dir__)
        MANIFEST_FILE = File.join(KIT_DIR, 'manifest.json')
        RESULTS_DIR = File.join(KIT_DIR, 'results')
        CONSUMER_DEFAULT_DIR = File.expand_path('../t0-worktrees-20260907/consumer', __dir__)

        REQUIRED_PROFILES = %w[visual research exact].freeze
        EXPECTED_PRODUCER_SHA = 'bd6782691ef8ba98f9d3baab698bc1cd961ce393'.freeze
        EXPECTED_LOADER_ID = 'bomc-next-v1'.freeze
        EXPECTED_SNAPSHOT_TREE_SHA256 = '703e65a95b459b852409abab50d53f7044c35f83a40a8ba48496c465786c0e6d'.freeze
        EXPECTED_PROFILE_CONTRACT_REVISION = 1

        def self.read_bomc_encoding_contract(bomc_path)
          return nil unless File.file?(bomc_path) && File.size(bomc_path) >= 32
          bytes = File.binread(bomc_path)
          return nil if bytes.bytesize < 32
          magic, major, minor, endian, flags, section_count, dir_offset = bytes[0, 32].unpack('a8vvVVVQ<')
          return nil unless magic == "BOMC\r\n\x1a\n".b

          compact = (flags & 0x10) != 0
          entry_bytes = compact ? 24 : 40
          entry_pack = compact ? 'vCCVVVVV' : 'vCCQ<Q<Q<VVV'
          dir_size = section_count * entry_bytes
          return nil if dir_offset + dir_size > bytes.bytesize

          section_count.times do |i|
            entry_raw = bytes.byteslice(dir_offset + i * entry_bytes, entry_bytes)
            vals = entry_raw.unpack(entry_pack)
            sec_type, sec_codec, sec_flags, sec_offset, stored_size, raw_size = vals[0, 6]
            if sec_type == 20 # SECTION_ENCODING_CONTRACT
              return nil if sec_offset + stored_size > bytes.bytesize
              sec_data = bytes.byteslice(sec_offset, stored_size)
              if sec_codec == 1 # DEFLATE
                sec_data = Zlib::Inflate.inflate(sec_data) rescue nil
              end
              return nil unless sec_data && sec_data.bytesize >= 76
              c_vals = sec_data.unpack('vCCQ<EEQ<EEEECCCCV')
              prof_map = { 1 => 'exact', 2 => 'research', 3 => 'visual' }
              return { profile: prof_map[c_vals[1]], encoder_revision: c_vals[-1] } if c_vals[0] == 1
              return nil
            end
          end
          nil
        rescue StandardError
          nil
        end

        def self.read_bomc_encoding_contract_profile(bomc_path)
          read_bomc_encoding_contract(bomc_path)&.dig(:profile)
        end

        def self.inspect_consumer_provenance(consumer_dir = CONSUMER_DEFAULT_DIR)
          unless Dir.exist?(consumer_dir)
            return { available: false, error: "Consumer dir not found at #{consumer_dir}" }
          end
          head_sha, _status = Open3.capture2('git', '-C', consumer_dir, 'rev-parse', 'HEAD') rescue nil
          head_sha = head_sha.to_s.strip
          status_out, _status = Open3.capture2('git', '-C', consumer_dir, 'status', '--porcelain') rescue nil
          uncommitted = status_out.to_s.split("\n").map(&:strip).reject(&:empty?)
          is_dirty = !uncommitted.empty?
          req = is_dirty ? 'Consumer checkout is dirty. All consumer modifications must be committed to a clean Git commit before browser benchmark certification, and the kit manifest must be pinned to that clean commit.' : nil

          {
            available: true,
            head_sha: head_sha,
            is_dirty: is_dirty,
            uncommitted_files: uncommitted,
            requirement: req
          }
        rescue StandardError => e
          { available: false, error: e.message }
        end

        def self.verify(results_dir = nil, consumer_dir: nil, skip_consumer_inspection: false)
          res_dir = results_dir ? File.expand_path(results_dir) : RESULTS_DIR
          errors = []
          warnings = []
          missing_profiles = []
          verified_captures = {}

          puts '======================================================================'
          puts '  SIBAMBO — T8 RUNTIME CAPTURE VERIFIER (HARDENED)'
          puts '======================================================================'

          # 1. Verify Manifest
          unless File.file?(MANIFEST_FILE)
            puts "  [FAIL] Manifest missing: #{MANIFEST_FILE}"
            return { status: 'failed', ready: false, errors: ['manifest.json not found'], warnings: [], missing_profiles: REQUIRED_PROFILES }
          end

          manifest = JSON.parse(File.read(MANIFEST_FILE))
          package_rel = manifest.dig('relative_paths', 'package') || 'sibambo_bom_engine_next_from_8082541.rbz'
          package_path = File.join(KIT_DIR, package_rel)

          unless File.file?(package_path)
            errors << "Package file missing: #{package_path}"
          end

          package_sha = File.file?(package_path) ? Digest::SHA256.file(package_path).hexdigest : nil
          if manifest['package_sha256'] && package_sha && manifest['package_sha256'] != package_sha
            errors << "Package SHA256 mismatch: manifest=#{manifest['package_sha256']} actual=#{package_sha}"
          end

          if manifest['producer_sha'] != EXPECTED_PRODUCER_SHA
            errors << "Producer SHA mismatch in manifest: expected #{EXPECTED_PRODUCER_SHA}, got #{manifest['producer_sha']}"
          end

          if manifest['loader_id'] != EXPECTED_LOADER_ID
            errors << "Loader ID mismatch in manifest: expected #{EXPECTED_LOADER_ID}, got #{manifest['loader_id']}"
          end

          if manifest['snapshot_tree_sha256'] != EXPECTED_SNAPSHOT_TREE_SHA256
            errors << "Snapshot tree digest mismatch in manifest: expected #{EXPECTED_SNAPSHOT_TREE_SHA256}, got #{manifest['snapshot_tree_sha256']}"
          end

          if manifest['profile_contract_revision'] != EXPECTED_PROFILE_CONTRACT_REVISION
            errors << "Profile contract revision mismatch in manifest: expected #{EXPECTED_PROFILE_CONTRACT_REVISION}, got #{manifest['profile_contract_revision']}"
          end

          unless manifest['consumer_sha'] && manifest['consumer_sha'].match?(/\A[0-9a-f]{40}\z/i)
            errors << "Manifest consumer_sha missing or not a 40-char hex string: #{manifest['consumer_sha']}"
          end

          # 2. Inspect Consumer Provenance
          consumer_info = nil
          unless skip_consumer_inspection
            consumer_info = inspect_consumer_provenance(consumer_dir || CONSUMER_DEFAULT_DIR)
            if consumer_info[:available]
              if consumer_info[:head_sha] && manifest['consumer_sha'] && consumer_info[:head_sha] != manifest['consumer_sha']
                errors << "Consumer SHA mismatch: manifest has #{manifest['consumer_sha']}, but actual consumer Git HEAD is #{consumer_info[:head_sha]}"
              end
              if consumer_info[:is_dirty]
                warnings << "Consumer checkout is dirty (#{consumer_info[:uncommitted_files].length} uncommitted files). Capture is provisional and certification is blocked."
              end
            end
          end

          puts "  Manifest check: #{errors.empty? ? 'PASS' : 'FAIL'}"

          # 3. Verify Profiles & Captures
          REQUIRED_PROFILES.each do |prof|
            capture_file = File.join(res_dir, "capture_#{prof}.json")
            unless File.file?(capture_file)
              missing_profiles << prof
              next
            end

            begin
              rec = JSON.parse(File.read(capture_file))
            rescue StandardError => e
              errors << "Corrupt capture JSON for #{prof}: #{e.message}"
              next
            end

            # Check schema fields
            required_fields = %w[
              schema_version release_id producer_sha consumer_sha loader_id profile_contract_revision
              package_sha256 snapshot_tree_sha256 profile timestamp source_model_path source_model_bytes
              source_model_sha256 output_bomc_path bomc_sha256 bomc_bytes sketchup_version ruby_version
              real_runtime_evidence export_errors timings
            ]
            required_fields.each do |field|
              if rec[field].nil?
                errors << "Capture #{prof} missing required field: #{field}"
              end
            end

            # Manifest identity agreement
            errors << "Release ID mismatch for #{prof}: expected #{manifest['release_id']}, got #{rec['release_id']}" if rec['release_id'] != manifest['release_id']
            errors << "Producer SHA mismatch for #{prof}: expected #{manifest['producer_sha']}, got #{rec['producer_sha']}" if rec['producer_sha'] != manifest['producer_sha']
            errors << "Consumer SHA mismatch for #{prof}: expected #{manifest['consumer_sha']}, got #{rec['consumer_sha']}" if rec['consumer_sha'] != manifest['consumer_sha']
            errors << "Loader ID mismatch for #{prof}: expected #{manifest['loader_id']}, got #{rec['loader_id']}" if rec['loader_id'] != manifest['loader_id']
            errors << "Profile contract revision mismatch for #{prof}: expected #{manifest['profile_contract_revision']}, got #{rec['profile_contract_revision']}" if rec['profile_contract_revision'].to_i != manifest['profile_contract_revision'].to_i
            errors << "Package SHA256 mismatch for #{prof}: expected #{manifest['package_sha256']}, got #{rec['package_sha256']}" if rec['package_sha256'] != manifest['package_sha256']
            errors << "Snapshot tree digest mismatch for #{prof}: expected #{manifest['snapshot_tree_sha256']}, got #{rec['snapshot_tree_sha256']}" if rec['snapshot_tree_sha256'] != manifest['snapshot_tree_sha256']

            # Profile match
            if rec['profile'] != prof
              errors << "Profile mismatch in capture #{prof}: expected #{prof}, got #{rec['profile']}"
            end

            # Source model validation
            unless rec['source_model_bytes'].is_a?(Integer) && rec['source_model_bytes'] > 0
              errors << "Capture #{prof} source_model_bytes must be a positive integer, got #{rec['source_model_bytes'].inspect}"
            end
            unless rec['source_model_sha256'].is_a?(String) && rec['source_model_sha256'].match?(/\A[0-9a-f]{64}\z/i)
              errors << "Capture #{prof} source_model_sha256 missing or not a 64-char hex string: #{rec['source_model_sha256'].inspect}"
            end
            if rec['source_model_path'].to_s.strip.empty?
              errors << "Capture #{prof} source_model_path is missing or empty"
            end

            # BOMC output validation & path traversal check
            bomc_path_val = rec['output_bomc_path'].to_s
            if bomc_path_val.empty?
              errors << "Capture #{prof} output_bomc_path is missing"
            else
              resolved_bomc = File.expand_path(bomc_path_val, res_dir)
              clean_res_dir = File.expand_path(res_dir)
              unless resolved_bomc.start_with?(clean_res_dir + File::SEPARATOR) || resolved_bomc == clean_res_dir
                errors << "Output BOMC path escapes results directory for #{prof}: #{bomc_path_val}"
                next
              end

              unless File.file?(resolved_bomc)
                errors << "BOMC file missing on disk for #{prof}: #{resolved_bomc}"
              else
                actual_bytes = File.size(resolved_bomc)
                if actual_bytes <= 0
                  errors << "BOMC file is empty on disk for #{prof}: #{resolved_bomc}"
                end
                if rec['bomc_bytes'] != actual_bytes
                  errors << "BOMC byte count mismatch for #{prof}: recorded #{rec['bomc_bytes']}, actual is #{actual_bytes}"
                end
                actual_bomc_sha = Digest::SHA256.file(resolved_bomc).hexdigest
                if rec['bomc_sha256'] != actual_bomc_sha
                  errors << "BOMC SHA256 mismatch for #{prof}: recorded #{rec['bomc_sha256']}, actual is #{actual_bomc_sha}"
                end

                # Section 20 encoding contract check
                actual_contract = read_bomc_encoding_contract(resolved_bomc)
                actual_bomc_prof = actual_contract&.dig(:profile)
                if actual_bomc_prof.nil?
                  errors << "Could not read Section 20 encoding contract profile from BOMC for #{prof}"
                elsif actual_bomc_prof != prof
                  errors << "Profile mismatch with BOMC encoding contract for #{prof}: capture declared '#{prof}', BOMC Section 20 encoded '#{actual_bomc_prof}'"
                end
                actual_bomc_revision = actual_contract&.dig(:encoder_revision)
                if actual_bomc_revision != manifest['profile_contract_revision']
                  errors << "Profile contract revision mismatch in BOMC for #{prof}: manifest #{manifest['profile_contract_revision']}, BOMC Section 20 #{actual_bomc_revision.inspect}"
                end
                if rec.key?('actual_bomc_revision') && rec['actual_bomc_revision'] != actual_bomc_revision
                  errors << "actual_bomc_revision mismatch in record for #{prof}: recorded #{rec['actual_bomc_revision'].inspect}, BOMC #{actual_bomc_revision.inspect}"
                end
                if rec['actual_bomc_profile'] && rec['actual_bomc_profile'] != prof
                  errors << "actual_bomc_profile mismatch in record for #{prof}: expected '#{prof}', got '#{rec['actual_bomc_profile']}'"
                end
              end
            end

            # Environment validation
            errors << "Capture #{prof} sketchup_version missing or empty" if rec['sketchup_version'].to_s.strip.empty?
            errors << "Capture #{prof} ruby_version missing or empty" if rec['ruby_version'].to_s.strip.empty?
            if rec['timestamp'].to_s.strip.empty?
              errors << "Capture #{prof} timestamp missing or empty"
            else
              begin
                Time.iso8601(rec['timestamp'])
              rescue ArgumentError
                errors << "Capture #{prof} timestamp is not a valid ISO-8601 string: #{rec['timestamp']}"
              end
            end

            # Fail-closed checks
            if rec['export_errors'].is_a?(Array) && !rec['export_errors'].empty?
              errors << "Export errors recorded in #{prof}: #{rec['export_errors'].join('; ')}"
            end
            if rec['export_status'] && rec['export_status'] != 'success'
              errors << "Capture #{prof} export_status is '#{rec['export_status']}', expected 'success'"
            end
            unless rec['real_runtime_evidence'] == true
              errors << "Capture #{prof} real_runtime_evidence must be true, got #{rec['real_runtime_evidence'].inspect}"
            end

            # Timings
            timings = rec['timings']
            if !timings.is_a?(Hash)
              errors << "Capture #{prof} timings object missing"
            else
              unless timings['total_wall_clock_ms'].is_a?(Numeric) && timings['total_wall_clock_ms'] > 0
                errors << "Capture #{prof} total_wall_clock_ms must be positive, got #{timings['total_wall_clock_ms'].inspect}"
              end
              if timings['stage_timing_evidence'] != 'complete'
                warnings << "Capture #{prof} stage timing evidence is incomplete (#{timings['stage_timing_evidence']})"
              end
            end

            verified_captures[prof] = rec
          end

          # 4. Cross-Profile Consistency Checks
          if verified_captures.length > 1
            source_shas = verified_captures.values.map { |c| c['source_model_sha256'] }.compact.uniq
            if source_shas.length > 1
              errors << "Inconsistent source model across profiles: captures refer to different source models (#{source_shas.join(', ')})"
            end
            pkg_shas = verified_captures.values.map { |c| c['package_sha256'] }.compact.uniq
            if pkg_shas.length > 1
              errors << "Inconsistent package SHA across profiles: captures refer to different packages (#{pkg_shas.join(', ')})"
            end
            prod_shas = verified_captures.values.map { |c| c['producer_sha'] }.compact.uniq
            if prod_shas.length > 1
              errors << "Inconsistent producer SHA across profiles (#{prod_shas.join(', ')})"
            end
            con_shas = verified_captures.values.map { |c| c['consumer_sha'] }.compact.uniq
            if con_shas.length > 1
              errors << "Inconsistent consumer SHA across profiles (#{con_shas.join(', ')})"
            end
          end

          # 5. Overall Status Resolution
          provisional = consumer_info ? consumer_info[:is_dirty] : false
          status = if !errors.empty?
                     'failed'
                   elsif !missing_profiles.empty?
                     'incomplete'
                   elsif provisional
                     'blocked'
                   else
                     'captured_pending_certification'
                   end

          ready = false # Strict invariant: capture preparation never promotes to ready: true

          puts "  Profiles captured: #{verified_captures.keys.inspect}"
          puts "  Profiles missing:  #{missing_profiles.inspect}" unless missing_profiles.empty?
          puts "  Errors count:      #{errors.length}"
          puts "  Warnings count:    #{warnings.length}"
          puts "  Verification status: #{status} (ready: #{ready}, provisional: #{provisional})"
          puts '======================================================================'

          {
            status: status,
            ready: ready,
            provisional: provisional,
            consumer_provenance: consumer_info,
            errors: errors,
            warnings: warnings,
            missing_profiles: missing_profiles,
            verified_captures: verified_captures
          }
        end
      end

      if __FILE__ == $PROGRAM_NAME
        res = T8CaptureVerifier.verify(ARGV[0])
        case res[:status]
        when 'captured_pending_certification'
          exit 0
        when 'incomplete'
          exit 2
        else
          exit 1
        end
      end
    RUBY
    File.write(verifier_path, code, encoding: 'UTF-8')
  end
end

if __FILE__ == $PROGRAM_NAME
  T8CaptureKitBuilder.build
end
