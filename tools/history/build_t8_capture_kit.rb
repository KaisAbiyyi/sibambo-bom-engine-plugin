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
  PINNED_PRODUCER_SHA = '7284982b26834f2635a839c6c7a1e687f83dca35'
  BASE_PRODUCER_SHA = '8082541d852cd68b9874231e41c6b9c967c74d26'
  PINNED_CONSUMER_SHA = 'd2f71f98e1376172cf5204f042d3b5e448aab71f'
  EXPECTED_SNAPSHOT_TREE_SHA256 = '71373d0fcda67580ab9333df8de4e1628d36b9f5c8d0c03f6e97061d8634a6f4'
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
      'profile_contract_revision' => e4_record['profileContractRevision'] || 2,
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
      # Usage in SketchUp Ruby Console:
      #   load 'D:/projects/sibambo/scratch/t8-capture-kit/capture_e4.rb'
      #   SibamboCaptureKit.export_profile(:visual)
      #   SibamboCaptureKit.export_profile(:research)
      #   SibamboCaptureKit.export_profile(:exact)
      #   # or run all three:
      #   SibamboCaptureKit.export_all

      require 'json'
      require 'time'
      require 'fileutils'
      require 'digest'

      module SibamboCaptureKit
        KIT_DIR = File.expand_path(__dir__)
        MANIFEST_PATH = File.join(KIT_DIR, 'manifest.json')
        RESULTS_DIR = File.join(KIT_DIR, 'results')
        FileUtils.mkdir_p(RESULTS_DIR)

        PROFILES = %i[visual research exact].freeze
        PRODUCER_SHA = '7284982b26834f2635a839c6c7a1e687f83dca35'.freeze
        RELEASE_ID = 'next-from-8082541'.freeze

        def self.ensure_extension_loaded!
          unless defined?(Sketchup)
            raise 'SibamboCaptureKit must be run inside Trimble SketchUp (Sketchup module not found).'
          end

          if defined?(SibamboHistory::Next_from_8082541)
            SibamboHistory::Next_from_8082541.load_engine
            return SibamboHistory::Next_from_8082541
          end

          plugins_dir = Sketchup.find_support_file('Plugins')
          if plugins_dir
            installed_entry = File.join(plugins_dir, 'sibambo_bom_engine_next_from_8082541', 'entry_next_from_8082541.rb')
            if File.file?(installed_entry)
              require installed_entry
              SibamboHistory::Next_from_8082541.load_engine
              return SibamboHistory::Next_from_8082541
            end
          end

          kit_staged_entry = File.join(KIT_DIR, 'staged', 'entry_next_from_8082541.rb')
          if File.file?(kit_staged_entry)
            require kit_staged_entry
            SibamboHistory::Next_from_8082541.load_engine
            return SibamboHistory::Next_from_8082541
          end

          raise "E4 candidate extension is not installed. Please install 'sibambo_bom_engine_next_from_8082541.rbz' via SketchUp Extension Manager first."
        end

        def self.export_profile(profile, output_dir: nil)
          ext_mod = ensure_extension_loaded!
          model = Sketchup.active_model

          if model.nil?
            raise 'No active model in SketchUp. Please open a real .skp model first.'
          end
          if model.path.to_s.strip.empty?
            raise 'The active model has not been saved to disk. Please save it as a .skp file first.'
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

          puts '======================================================================'
          puts "  SIBAMBO T8 CAPTURE: Exporting Profile '#{prof_sym.to_s.upcase}'"
          puts "  Model:  #{model.path}"
          puts "  Output: #{output_bomc_path}"
          puts '======================================================================'

          manifest = File.file?(MANIFEST_PATH) ? JSON.parse(File.read(MANIFEST_PATH)) : {}
          package_sha256 = manifest['package_sha256'] || manifest['catalog_package_sha256']

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

          stage_evidence = if stage_timings.length >= 3
                             'complete'
                           elsif !stage_timings.empty?
                             'partial'
                           else
                             'incomplete'
                           end

          bomc_sha256 = File.file?(output_bomc_path) ? Digest::SHA256.file(output_bomc_path).hexdigest : nil
          bomc_bytes = File.file?(output_bomc_path) ? File.size(output_bomc_path) : 0

          record = {
            'schema_version' => 't8-runtime-capture-v1',
            'release_id' => RELEASE_ID,
            'producer_sha' => PRODUCER_SHA,
            'profile' => prof_sym.to_s,
            'timestamp' => Time.now.utc.iso8601,
            'source_model_path' => model.path.to_s.gsub('\\', '/'),
            'source_model_bytes' => (File.size(model.path) rescue nil),
            'output_bomc_path' => output_bomc_path.gsub('\\', '/'),
            'bomc_sha256' => bomc_sha256,
            'bomc_bytes' => bomc_bytes,
            'package_sha256' => package_sha256,
            'sketchup_version' => Sketchup.version,
            'ruby_version' => defined?(RUBY_DESCRIPTION) ? RUBY_DESCRIPTION : RUBY_VERSION,
            'real_runtime_evidence' => true,
            'export_errors' => export_errors,
            'timings' => {
              'total_wall_clock_ms' => total_wall_clock_ms,
              'stage_timings' => stage_timings,
              'stage_timing_evidence' => stage_evidence
            }
          }

          File.write(capture_json_path, JSON.pretty_generate(record), encoding: 'UTF-8')

          if export_errors.empty? && File.file?(output_bomc_path)
            puts "  [SUCCESS] Profile '#{prof_sym}' exported in #{total_wall_clock_ms} ms."
            puts "  BOMC file: #{output_bomc_path} (#{bomc_bytes} bytes, SHA256: #{bomc_sha256[0..11]}...)"
            puts "  Capture record: #{capture_json_path}"
          else
            puts "  [FAILED] Profile '#{prof_sym}' failed. See #{capture_json_path} for details."
          end
          puts '======================================================================'

          record
        end

        def self.export_all(output_dir: nil)
          results = {}
          PROFILES.each do |prof|
            results[prof] = export_profile(prof, output_dir: output_dir)
          end
          session_file = File.join(output_dir || RESULTS_DIR, 't8_capture_session.json')
          File.write(session_file, JSON.pretty_generate({
            'session_id' => "t8-capture-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}",
            'completed_at' => Time.now.utc.iso8601,
            'profiles' => results
          }), encoding: 'UTF-8')
          puts "\nAll 3 profiles exported. Session record written to: #{session_file}"
          results
        end
      end
    RUBY
    File.write(script_path, code, encoding: 'UTF-8')
  end

  def self.generate_operator_guide(kit_dir, package_sha256)
    guide_path = File.join(kit_dir, 'OPERATOR_GUIDE.md')
    content = <<~MARKDOWN
      # SIBAMBO T8 Runtime Capture Kit — Operator Instructions

      **Target Release**: \`next-from-8082541\` (Candidate E4)  
      **Producer SHA**: \`7284982b26834f2635a839c6c7a1e687f83dca35\`  
      **Package SHA-256**: \`#{package_sha256}\`  
      **Kit Path**: \`#{kit_dir.gsub('\\', '/')}\`  

      ---

      ## Step 1: Open SketchUp 2026 Pro and Open Model
      1. Launch **Trimble SketchUp Pro 2026**.
      2. Open a real architectural \`.skp\` model (e.g. \`RUMAH L.skp\` or \`RUMAH G.skp\`).
      3. Verify the model is saved on disk.

      ---

      ## Step 2: Install Candidate E4 RBZ Package
      1. In SketchUp, open **Extensions > Extension Manager**.
      2. Click **Install Extension...** at the bottom left.
      3. Select:
         \`#{File.join(kit_dir, 'sibambo_bom_engine_next_from_8082541.rbz').gsub('/', '\\')}\`
      4. Confirm installation. The extension **"Sibambo BOM Engine — Next Evolution (Candidate from 8082541)"** is now active.

      ---

      ## Step 3: Run Captures via Ruby Console
      Open **Window > Ruby Console** in SketchUp, then copy and paste the command for each profile.

      ### Option A: Run All 3 Profiles at Once (Recommended)
      ```ruby
      load '#{File.join(kit_dir, 'capture_e4.rb').gsub('\\', '/')}'; SibamboCaptureKit.export_all
      ```

      ### Option B: Run Profiles Individually
      - **Visual Profile**:
        ```ruby
        load '#{File.join(kit_dir, 'capture_e4.rb').gsub('\\', '/')}'; SibamboCaptureKit.export_profile(:visual)
        ```
      - **Research Profile**:
        ```ruby
        load '#{File.join(kit_dir, 'capture_e4.rb').gsub('\\', '/')}'; SibamboCaptureKit.export_profile(:research)
        ```
      - **Exact Profile**:
        ```ruby
        load '#{File.join(kit_dir, 'capture_e4.rb').gsub('\\', '/')}'; SibamboCaptureKit.export_profile(:exact)
        ```

      ---

      ## Step 4: Expected Output Files
      After export, the following files will be created in \`#{File.join(kit_dir, 'results').gsub('\\', '/')}/\`:
      - `<model>__E4__VISUAL.bomc` and `capture_visual.json`
      - `<model>__E4__RESEARCH.bomc` and `capture_research.json`
      - `<model>__E4__EXACT.bomc` and `capture_exact.json`
      - `t8_capture_session.json`

      ---

      ## Step 5: Verification
      From terminal/PowerShell, verify the capture kit evidence:
      ```powershell
      ruby #{File.join(kit_dir, 'verify_capture.rb').gsub('\\', '/')}
      ```

      ---

      ## Step 6: Uninstall / Rollback Package
      When done with capture:
      1. Open **Extensions > Extension Manager**.
      2. Find **Sibambo BOM Engine — Next Evolution (Candidate from 8082541)**.
      3. Click **Uninstall** (or toggle **Disabled**).
      4. Alternatively, remove \`sibambo_bom_engine_next_from_8082541*\` from your SketchUp \`Plugins\` folder.

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
      # Validates manifest, capture JSON schema, file existence, SHA256 digests, and profile identities.

      require 'json'
      require 'digest'
      require 'fileutils'

      module T8CaptureVerifier
        KIT_DIR = File.expand_path(__dir__)
        MANIFEST_FILE = File.join(KIT_DIR, 'manifest.json')
        RESULTS_DIR = File.join(KIT_DIR, 'results')

        REQUIRED_PROFILES = %w[visual research exact].freeze
        EXPECTED_PRODUCER_SHA = '7284982b26834f2635a839c6c7a1e687f83dca35'.freeze
        EXPECTED_LOADER_ID = 'bomc-next-v1'.freeze
        EXPECTED_SNAPSHOT_TREE_SHA256 = '71373d0fcda67580ab9333df8de4e1628d36b9f5c8d0c03f6e97061d8634a6f4'.freeze

        def self.verify(results_dir = nil)
          res_dir = results_dir ? File.expand_path(results_dir) : RESULTS_DIR
          errors = []
          warnings = []
          missing_profiles = []

          puts '======================================================================'
          puts '  SIBAMBO — T8 RUNTIME CAPTURE VERIFIER'
          puts '======================================================================'

          # 1. Verify Manifest
          unless File.file?(MANIFEST_FILE)
            puts "  [FAIL] Manifest missing: #{MANIFEST_FILE}"
            return { status: 'failed', ready: false, errors: ['manifest.json not found'] }
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

          puts "  Manifest check: #{errors.empty? ? 'PASS' : 'FAIL'}"

          # 2. Verify Profiles & Captures
          verified_captures = {}

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
            %w[schema_version release_id producer_sha profile timestamp source_model_path output_bomc_path bomc_sha256 package_sha256 sketchup_version timings].each do |field|
              unless rec.key?(field) && !rec[field].nil?
                errors << "Capture #{prof} missing required field: #{field}"
              end
            end

            if rec['profile'] != prof
              errors << "Profile mismatch in capture #{prof}: expected #{prof}, got #{rec['profile']}"
            end

            if rec['producer_sha'] != EXPECTED_PRODUCER_SHA
              errors << "Producer SHA mismatch in capture #{prof}: expected #{EXPECTED_PRODUCER_SHA}, got #{rec['producer_sha']}"
            end

            bomc_path = rec['output_bomc_path']
            unless bomc_path && File.file?(bomc_path)
              errors << "BOMC file missing on disk for #{prof}: #{bomc_path}"
            end

            if bomc_path && File.file?(bomc_path)
              actual_bomc_sha = Digest::SHA256.file(bomc_path).hexdigest
              if rec['bomc_sha256'] && actual_bomc_sha != rec['bomc_sha256']
                errors << "BOMC SHA256 mismatch for #{prof}: recorded=#{rec['bomc_sha256']} actual=#{actual_bomc_sha}"
              end
            end

            if rec['export_errors'] && !rec['export_errors'].empty?
              errors << "Export errors recorded in #{prof}: #{rec['export_errors'].join('; ')}"
            end

            unless rec['real_runtime_evidence'] == true
              warnings << "Capture #{prof} does not declare real_runtime_evidence: true"
            end

            timing_evidence = rec.dig('timings', 'stage_timing_evidence')
            if timing_evidence == 'incomplete' || timing_evidence.nil?
              warnings << "Capture #{prof} stage timing evidence is incomplete"
            end

            verified_captures[prof] = rec
          end

          status = if !errors.empty?
                     'failed'
                   elsif !missing_profiles.empty?
                     'incomplete'
                   else
                     'captured_pending_certification'
                   end

          ready = false # Strict invariant: capture preparation never promotes to ready: true

          puts "  Profiles captured: #{verified_captures.keys.inspect}"
          puts "  Profiles missing:  #{missing_profiles.inspect}" unless missing_profiles.empty?
          puts "  Errors count:      #{errors.length}"
          puts "  Warnings count:    #{warnings.length}"
          puts "  Verification status: #{status} (ready: #{ready})"
          puts '======================================================================'

          {
            status: status,
            ready: ready,
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
