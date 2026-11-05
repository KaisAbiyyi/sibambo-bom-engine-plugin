# frozen_string_literal: true
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'securerandom'
require 'time'
require 'tmpdir'
require_relative 'bomc_format'
require_relative 'bomc_encoding_contract'
require_relative 'native_export_lease'

module BOMEngine
  module OvernightBatch
    SCHEMA = 'sibambo-overnight-batch-v3'.freeze
    LEGACY_SCHEMA = 'sibambo-overnight-batch-v2'.freeze
    SOURCE_ROOT = 'D:/projects/sibambo/skps'.freeze
    OUTPUT_ROOT = 'D:/projects/sibambo/private-evidence/batch-exports'.freeze
    PROFILES = %w[exact visual].freeze
    ENGINES = %w[e2 e3 e4].freeze
    FORMATS = {'e2' => 'canonical-v3', 'e3' => 'cleanpkg', 'e4' => 'bomc-1.2'}.freeze
    EXTENSIONS = {'e2' => '.json.gz', 'e3' => '.cleanpkg', 'e4' => '.bomc'}.freeze
    MIN_FREE_BYTES = 512 * 1024 * 1024
    RUN_ID = /\A\d{8}T\d{6}Z-[a-f0-9]{10}\z/
    class Unsafe < StandardError; end
    class Cancelled < StandardError; end

    module_function
    def jobs(run)
      run.fetch('models').flat_map do |row|
        row.fetch('exports').flat_map { |engine, records| records.map { |profile, record| [row, engine, profile, record] } }
      end
    end
    def artifact_path(directory, engine, profile)
      raise Unsafe, 'Unsupported batch version/profile.' unless ENGINES.include?(engine) && PROFILES.include?(profile)
      name = engine == 'e4' ? 'artifact.bomc' : "artifact__#{engine.upcase}__#{profile.upcase}#{EXTENSIONS.fetch(engine)}"
      File.join(directory, name)
    end
    def canonical(path)
      value = File.expand_path(path.to_s).tr('\\', '/').sub(%r{/+\z}, '')
      Gem.win_platform? ? value.downcase : value
    end
    def within?(path, root)
      child, parent = canonical(path), canonical(root)
      child == parent || child.start_with?("#{parent}/")
    end
    # Check every existing ancestor, including Windows junction/reparse aliases.
    # Private directories must not be edited by another process during a run.
    def unlinked!(path)
      current = File.expand_path(path.to_s)
      loop do
        if File.exist?(current) || File.symlink?(current)
          raise Unsafe, "Linked/aliased path refused: #{current}" if File.symlink?(current) || canonical(File.realpath(current)) != canonical(current)
        end
        parent = File.dirname(current)
        break if parent == current
        current = parent
      end
      path
    end
    def existing_safe_file!(path, root)
      raise Unsafe, 'File escapes private output root.' unless path.is_a?(String) && within?(path, root)
      unlinked!(path)
      raise Unsafe, 'Required evidence file is missing.' unless File.file?(path)
      path
    end
    def fingerprint(path)
      unlinked!(path)
      raise Unsafe, "Missing file: #{path}" unless File.file?(path)
      before = File.stat(path)
      sha = Digest::SHA256.file(path).hexdigest
      after = File.stat(path)
      raise Unsafe, 'File changed during fingerprint.' unless [before.size, before.mtime, before.ino] == [after.size, after.mtime, after.ino]
      { 'bytes' => after.size, 'sha256' => sha }
    end
    def timestamp; Time.now.utc.iso8601(3); end
    def read_json(path, limit: 8 * 1024 * 1024)
      raise Unsafe, 'JSON evidence exceeds bounded read limit.' if File.size(path) > limit
      JSON.parse(File.read(path, encoding: 'UTF-8'))
    end
    def write_new(path, data)
      unlinked!(path)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
        f.write(JSON.pretty_generate(data) + "\n"); f.flush; f.fsync
      end
      fingerprint(path).merge('path' => path)
    end
    def runtime_identity
      paths = Dir.glob(File.join(__dir__, '**', '*')).select do |p|
        File.file?(p) && !p.include?('/tests/') && %w[.rb .html .txt].include?(File.extname(p).downcase)
      end.sort
      digest = Digest::SHA256.new
      paths.each do |p|
        unlinked!(p)
        digest.update(p.delete_prefix("#{__dir__}/").tr('\\', '/')).update("\0").update(Digest::SHA256.file(p).digest)
      end
      { 'files_sha256' => digest.hexdigest, 'file_count' => paths.length,
        'identity_kind' => 'runtime_disk_inventory_at_batch_load',
        'build_sha' => (defined?(Branding) ? Branding.build_sha : 'unavailable'),
        'supported_engines' => ENGINES, 'formats' => FORMATS,
        'package_sha256' => nil, 'authenticated_producer' => false }
    end
    # A disk inventory is deliberately not described as an authenticated loaded
    # package. Restart after any runtime modification; native loading is a gate.
    INITIAL_RUNTIME = runtime_identity.freeze

    class Catalog
      attr_reader :root, :output_root
      def initialize(root, output_root: OUTPUT_ROOT, require_d: false)
        @root, @output_root = File.expand_path(root.to_s), File.expand_path(output_root.to_s)
        OvernightBatch.unlinked!(@root); OvernightBatch.unlinked!(@output_root)
        raise Unsafe, 'Source root must be a readable directory.' unless File.directory?(@root) && File.readable?(@root)
        if require_d && [@root, @output_root].any? { |p| !p.match?(/\AD:[\\\/]/i) }
          raise Unsafe, 'Sources and private outputs must be on D:.'
        end
        raise Unsafe, 'Output must be outside source root.' if OvernightBatch.within?(@output_root, @root) || OvernightBatch.within?(@root, @output_root)
      end
      def scan
        rows = []
        Find.find(@root) do |path|
          OvernightBatch.unlinked!(path)
          next unless File.file?(path) && File.extname(path).casecmp('.skp').zero?
          relative = path.tr('\\', '/').delete_prefix(@root.tr('\\', '/') + '/')
          row = OvernightBatch.fingerprint(path).merge('relative' => relative,
            'key' => "model-#{Digest::SHA256.hexdigest(relative.downcase)[0, 20]}")
          rows << row
          yield row if block_given?
        end
        raise Unsafe, 'Case-insensitive model key collision.' unless rows.map { |r| r['key'] }.uniq.size == rows.size
        rows.sort_by { |r| [r['relative'].downcase, r['relative']] }
      end
      def assert_source!(row)
        relative = row.fetch('relative')
        raise Unsafe, 'Invalid relative SKP path.' unless relative.is_a?(String) && !relative.empty? && !relative.match?(/[:\\]/) && relative.split('/').none? { |s| s.empty? || %w[. ..].include?(s) } && File.extname(relative).casecmp('.skp').zero?
        expected_key = "model-#{Digest::SHA256.hexdigest(relative.downcase)[0, 20]}"
        raise Unsafe, 'Model key differs from source identity.' unless row['key'] == expected_key
        path = File.expand_path(relative, @root)
        raise Unsafe, 'Source escaped selected root.' unless OvernightBatch.within?(path, @root)
        raise Unsafe, "Source changed: #{relative}" unless OvernightBatch.fingerprint(path) == row.slice('bytes', 'sha256')
        path
      end
    end

    class Store
      attr_reader :root
      def initialize(root: OUTPUT_ROOT, profile_checker: nil)
        @root = File.expand_path(root)
        OvernightBatch.unlinked!(@root)
        @profile_checker = profile_checker || method(:check_bomc_profile)
      end
      def prepare!
        OvernightBatch.unlinked!(@root)
        FileUtils.mkdir_p(@root, mode: 0o700)
        raise Unsafe, 'Output directory is not writable.' unless File.writable?(@root)
      end
      def directory(id)
        raise Unsafe, 'Invalid batch run ID.' unless id.to_s.match?(RUN_ID)
        path = File.join(@root, id)
        OvernightBatch.unlinked!(path)
        path
      end
      def lock(id)
        prepare!
        path = File.join(directory(id), 'writer.lock')
        OvernightBatch.unlinked!(path)
        f = File.open(path, File::RDWR | File::CREAT, 0o600)
        unless f.flock(File::LOCK_EX | File::LOCK_NB)
          f.close; raise Unsafe, 'This run has another writer; close it before resuming.'
        end
        f
      end
      def run_ids
        return [] unless Dir.exist?(@root)
        OvernightBatch.unlinked!(@root)
        Dir.children(@root).grep(RUN_ID).sort.reverse.select { |id| File.directory?(directory(id)) }
      end
      def load(id)
        dir = directory(id)
        snapshots = File.join(dir, 'snapshots'); OvernightBatch.unlinked!(snapshots)
        Dir.glob(File.join(snapshots, 'state-*.json')).sort.reverse.each do |path|
          begin
            OvernightBatch.existing_safe_file!(path, dir)
            data = OvernightBatch.read_json(path, limit: 32 * 1024 * 1024)
            next unless [SCHEMA, LEGACY_SCHEMA].include?(data['schema']) && data['run_id'] == id && data['output_root'] == @root
            # A torn latest snapshot must not cause an EXCL collision on recovery.
            data['sequence'] = [data.fetch('sequence'), snapshot_sequence(dir)].max
            return data
          rescue JSON::ParserError, SystemCallError
            next
          end
        end
        raise Unsafe, 'No valid snapshot; investigate manually. No files were removed.'
      end
      def snapshot_sequence(dir)
        Dir.glob(File.join(dir, 'snapshots', 'state-*.json')).map { |p| File.basename(p)[/state-(\d+)\.json/, 1].to_i }.max || 0
      end
      def save(run)
        raise Unsafe, 'Historical batch is read-only; start a new run.' unless run['schema'] == SCHEMA
        dir = directory(run.fetch('run_id'))
        raise Unsafe, 'Missing run directory.' unless Dir.exist?(dir)
        snapshots = File.join(dir, 'snapshots'); OvernightBatch.unlinked!(snapshots)
        FileUtils.mkdir_p(snapshots, mode: 0o700)
        run['sequence'] = [run.fetch('sequence', 0), snapshot_sequence(dir)].max + 1
        run['updated_at'] = OvernightBatch.timestamp
        OvernightBatch.write_new(File.join(snapshots, format('state-%09d.json', run['sequence'])), run)
        # Snapshots are authoritative. manifest.json is an atomic convenience view.
        current = File.join(dir, 'manifest.json'); OvernightBatch.unlinked!(current)
        tmp = File.join(dir, "manifest-#{SecureRandom.hex(8)}.part")
        begin
          OvernightBatch.write_new(tmp, run)
          File.rename(tmp, current)
        ensure
          File.delete(tmp) if File.file?(tmp)
        end
        run
      end
      def create(catalog:, selected:, profiles:, runtime:, stop_on_error:, free_bytes:, engines: ['e4'])
        raise Unsafe, 'Choose at least one SKP, without duplicates.' if selected.empty? || selected.uniq.size != selected.size
        raise Unsafe, 'Choose Exact, Visual, or both.' if profiles.empty? || (profiles - PROFILES).any? || profiles.uniq.size != profiles.size
        raise Unsafe, 'Choose E2, E3, E4, or a combination without duplicates.' unless engines.is_a?(Array) && !engines.empty? && (engines - ENGINES).empty? && engines.uniq.size == engines.size
        engines = ENGINES.select { |engine| engines.include?(engine) }
        profiles = PROFILES.select { |profile| profiles.include?(profile) }
        rows = catalog.scan.to_h { |r| [r['relative'], r] }
        raise Unsafe, 'Selection is stale; refresh.' unless selected.all? { |s| rows.key?(s) }
        required = MIN_FREE_BYTES + selected.sum { |s| rows.fetch(s)['bytes'] * profiles.size * engines.size }
        raise Unsafe, "Insufficient disk space: need at least #{required} bytes." unless free_bytes.is_a?(Integer) && free_bytes >= required
        prepare!
        id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(5)}"
        Dir.mkdir(directory(id), 0o700) # EXCL: a collision is a failure, never overwrite.
        run = {'schema' => SCHEMA, 'run_id' => id, 'sequence' => 0, 'status' => 'pending',
          'source_root' => catalog.root, 'output_root' => @root, 'runtime' => runtime,
          'engines' => engines, 'profiles' => profiles,
          'created_at' => OvernightBatch.timestamp, 'stop_on_error' => stop_on_error == true,
          'certified' => false, 'research_qualified' => false,
          'models' => selected.map { |s| rows.fetch(s) }.sort_by { |r| [r['relative'].downcase, r['relative']] }.map do |row|
            row.merge('exports' => engines.to_h do |engine|
              [engine, profiles.to_h do |p|
                prior, reason = reusable(row, p, runtime, catalog.root, engine: engine)
                [p, prior ? prior.merge('status' => 'reused') : {'status' => 'pending', 'reuse_reason' => reason, 'attempts' => []}]
              end]
            end)
          end}
        save(run)
      end
      def reusable(source, profile, runtime, source_root, engine: 'e4')
        incomplete = false
        run_ids.each do |id|
          begin
            run = load(id)
            next unless run['schema'] == SCHEMA
            next unless OvernightBatch.canonical(run['source_root']) == OvernightBatch.canonical(source_root)
            row = Array(run['models']).find { |r| r['relative'] == source['relative'] }
            record = row && row.fetch('exports', {}).fetch(engine, {})[profile]
            next unless record
            incomplete = true
            next unless row.slice('bytes', 'sha256') == source.slice('bytes', 'sha256')
            return [Marshal.load(Marshal.dump(record)), 'verified_reuse'] if valid_record?(record, row, profile, run, runtime, engine: engine)
          rescue Unsafe, JSON::ParserError, SystemCallError, KeyError, TypeError
            incomplete = true
          end
        end
        # Filename discovery is only an incomplete-evidence hint, never reuse.
        legacy_dir = File.join(source_root, File.dirname(source['relative']), 'model-eval-exports')
        OvernightBatch.unlinked!(legacy_dir)
        if Dir.exist?(legacy_dir)
          base = File.basename(source['relative'], File.extname(source['relative']))
          incomplete ||= Dir.children(legacy_dir).any? { |name| name.downcase.start_with?(base.downcase + '__') && name.downcase.end_with?("__#{profile}#{EXTENSIONS.fetch(engine)}") }
        end
        [nil, incomplete ? 'needs_verification' : 'no_previous_verified_artifact']
      end
      def evidence(ref)
        path = OvernightBatch.existing_safe_file!(ref.fetch('path'), @root)
        raise Unsafe, 'Evidence hash/bytes mismatch.' unless OvernightBatch.fingerprint(path) == ref.slice('bytes', 'sha256')
        OvernightBatch.read_json(path)
      end
      def valid_record?(record, source, profile, run, runtime, engine: 'e4')
        return false unless %w[success reused].include?(record['status']) && PROFILES.include?(profile)
        return false unless run['schema'] == SCHEMA && ENGINES.include?(engine)
        return false unless record.values_at('format', 'engine_wire', 'engine_display', 'profile', 'validation') == [FORMATS.fetch(engine), engine, engine.upcase, profile, 'passed']
        return false unless run['runtime'] == runtime && record['runtime'] == runtime
        path = OvernightBatch.existing_safe_file!(record['path'], @root)
        artifact = OvernightBatch.fingerprint(path)
        return false unless artifact == record.slice('bytes', 'sha256')
        return false if engine == 'e4' && profile == 'exact' && artifact['bytes'] >= source['bytes']
        trace = evidence(record.fetch('performance_receipt'))
        return false unless trace['schema'] == 'sibambo-performance-trace-v1' && trace['status'] == 'success' && trace['total_wall_ms'].is_a?(Numeric) && trace['total_wall_ms'] >= 0
        meta = trace.fetch('metadata')
        return false unless meta.values_at('engine', 'format', 'profile') == [engine, FORMATS.fetch(engine), profile]
        if engine == 'e4'
          return false unless meta.fetch('source').slice('bytes', 'sha256') == source.slice('bytes', 'sha256')
        else
          model = meta.fetch('source_model')
          return false unless model.values_at('sourceBytes', 'sourceSha256') == source.values_at('bytes', 'sha256')
          provenance = evidence(record.fetch('provenance_receipt'))
          return false unless provenance['schema'] == 'sibambo-research-provenance-v1' && provenance['engine'] == engine
          return false unless provenance.fetch('artifact').slice('bytes', 'sha256', 'format', 'profile') == artifact.merge('format' => FORMATS.fetch(engine), 'profile' => profile)
          return false unless provenance.fetch('model').values_at('sourceBytes', 'sourceSha256') == source.values_at('bytes', 'sha256')
          producer_sha = provenance.dig('producer', 'sourceTreeSha256')
          return false unless producer_sha.is_a?(String) && producer_sha.match?(/\A[a-f0-9]{64}\z/) && producer_sha == meta['source_tree_sha256']
        end
        return false unless meta.fetch('artifact').slice('bytes', 'sha256') == artifact
        validation = evidence(record.fetch('validation_receipt'))
        return false unless validation['schema'] == 'sibambo-batch-validation-v2' && validation['runtime'] == runtime && validation['profile'] == profile && validation['engine'] == engine
        return false unless validation['source'] == source.slice('bytes', 'sha256') && validation['artifact'] == artifact
        return false unless validation['performance_receipt'] == record['performance_receipt'] && validation.dig('report', 'passed') == true && validation.dig('report', 'profile').to_s == profile
        if engine == 'e4'
          @profile_checker.call(path, profile) == true
        else
          # The exporter and host read back the actual wire format before this
          # binding is written. Reuse streams artifact hashes and rechecks the
          # immutable proof; do not parse a large E2/E3 file on every UI scan.
          validation['provenance_receipt'] == record['provenance_receipt'] &&
            validation.dig('report', 'engine') == engine &&
            validation.dig('report', 'sha256') == artifact['sha256'] &&
            validation.dig('report', 'bytes') == artifact['bytes']
        end
      rescue StandardError
        false # Missing/old/unrecognized evidence is Needs Verification, never PASS.
      end
      # Bounded header/directory/76-byte contract inspection, plus streamed SHA
      # above. Full fidelity proof is bound to the original validation sidecar.
      def check_bomc_profile(path, profile)
        File.open(path, 'rb') do |f|
          header = f.read(32)
          return false unless header && header.bytesize == 32
          magic, major, minor, endian, flags, count, offset = header.unpack(BOMC::HEADER_PACK)
          return false unless magic == BOMC::MAGIC && major == 1 && minor == 2 && endian == BOMC::ENDIAN_MARKER && (flags & BOMC::FLAG_COMPACT_DIRECTORY) != 0
          return false unless count.between?(1, DecodeBudget::MAX_SECTIONS) && offset >= 32 && offset + count * 24 <= f.size
          f.seek(offset)
          descriptors = count.times.map { f.read(24).unpack(BOMC::COMPACT_DIRECTORY_PACK) }
          return false unless descriptors.all? { |d| d[3] >= BOMC::Binary.align(offset + count * 24) && d[3] % 8 == 0 && d[3] + d[4] <= f.size }
          return false if descriptors.sort_by { |d| d[3] }.each_cons(2).any? { |a,b| a[3] + a[4] > b[3] }
          contracts = descriptors.select { |d| d[0] == 20 }
          return false unless contracts.size == 1
          _, codec, _, start, stored_size, raw_size, _, crc = contracts.first
          return false unless raw_size == 76 && stored_size.between?(1, 1024) && [0, 1].include?(codec)
          f.seek(start); stored = f.read(stored_size)
          return false unless Zlib.crc32(stored) == crc
          raw = ''.b
          if codec == 0
            raw = stored
          else
            z = Zlib::Inflate.new
            begin
              # Byte-wise input keeps output allocations bounded even for bombs.
              stored.each_byte do |byte|
                raw << z.inflate(byte.chr)
                return false if raw.bytesize > 76
              end
              return false unless z.finished? && z.total_in == stored_size
            ensure
              z.close
            end
          end
          BOMCEncodingContract.decode(raw)[:profile].to_s == profile
        end
      rescue StandardError
        false
      end
    end

    class SketchupHost
      def safe_to_switch?
        m = Sketchup.active_model
        m && m.respond_to?(:modified?) && !m.modified? && (!m.path.to_s.empty? || m.entities.length == 0)
      end
      def open(path)
        raise Unsafe, 'Unsaved/dirty active model: save or resolve it manually; batch paused.' unless safe_to_switch?
        m = Sketchup.active_model
        unless OvernightBatch.canonical(m.path) == OvernightBatch.canonical(path)
          raise Unsafe, 'SketchUp refused open; batch paused.' unless Sketchup.open_file(path)
          m = Sketchup.active_model
        end
        raise Unsafe, 'Wrong active model or dirty model after open.' unless safe_after_failure?(path)
        m
      end
      def safe_after_failure?(path)
        m = Sketchup.active_model
        m && OvernightBatch.canonical(m.path) == OvernightBatch.canonical(path) && safe_to_switch?
      end
      def export(model, path, profile, engine: 'e4', &progress)
        raise Unsafe, 'Unsupported batch version.' unless ENGINES.include?(engine)
        raise Unsafe, 'Another conversion is active.' if ConversionJob.active && ConversionJob.active.running?
        temp = File.join(File.dirname(path), 'temp'); FileUtils.mkdir_p(temp)
        old = ENV.values_at('TEMP', 'TMP')
        begin
          ENV['TEMP'] = ENV['TMP'] = temp
          settings = BOMCProcessing.from_ui(batch_mode: 'auto')
          if engine == 'e4'
            BOMCExtension.export(model, output_path: path, profile: profile.to_sym,
              settings: settings, progress: progress)
          else
            require_relative 'evolution_exporter'
            result = EvolutionExporter.export(model, engine: engine.to_sym, profile: profile.to_sym,
              output_path: path, processing: settings, progress: progress, active_model: -> { Sketchup.active_model })
            result.merge(validation: {report: result.fetch(:validation)})
          end
        ensure
          ENV['TEMP'], ENV['TMP'] = old
        end
      end
      def validate(path, profile, engine: 'e4')
        return Store.new.check_bomc_profile(path, profile) if engine == 'e4'
        return false unless ENGINES.include?(engine)
        require_relative 'evolution_validator'
        EvolutionValidator.validate_file!(path, engine: engine, expected_profile: profile)[:passed] == true
      end
      def runtime
        current = OvernightBatch.runtime_identity
        raise Unsafe, 'Runtime files changed since batch code loaded; restart SketchUp.' unless current == INITIAL_RUNTIME
        current.merge('sketchup_version' => Sketchup.version.to_s, 'ruby_version' => RUBY_VERSION)
      end
      def free_bytes(path)
        require 'fiddle'
        dir = File.expand_path(path)
        dir = File.dirname(dir) until Dir.exist?(dir)
        OvernightBatch.unlinked!(dir)
        dll = Fiddle.dlopen('kernel32.dll')
        fn = Fiddle::Function.new(dll['GetDiskFreeSpaceExW'], [Fiddle::TYPE_VOIDP] * 4, Fiddle::TYPE_INT)
        wide = (dir.tr('/', '\\') + "\0").encode('UTF-16LE')
        buf = Fiddle::Pointer.malloc(8)
        raise Unsafe, 'Disk free preflight failed.' if fn.call(wide, buf, 0, 0) == 0
        buf[0, 8].unpack1('Q<')
      rescue LoadError, Fiddle::DLError
        raise Unsafe, 'Windows disk free preflight unavailable.'
      end
    end

    class Queue
      attr_reader :run
      def initialize(store:, catalog:, run:, host:)
        raise Unsafe, 'Historical batch is read-only; start a new run.' unless run['schema'] == SCHEMA
        @store, @catalog, @run, @host = store, catalog, run, host
        @attempted = {}; @cancel_requested = @pause_requested = @stepping = false
        @lock = store.lock(run.fetch('run_id'))
        begin
          verify!
          reverify_existing!
          @run['status'] = 'paused' unless %w[complete complete_with_failures cancelled pending].include?(@run['status'])
          @store.save(@run)
        rescue StandardError
          close; raise
        end
      end
      def verify!
        raise Unsafe, 'Historical batch is read-only; start a new run.' unless @run['schema'] == SCHEMA
        raise Unsafe, 'Source root mismatch.' unless OvernightBatch.canonical(@run.fetch('source_root')) == OvernightBatch.canonical(@catalog.root)
        raise Unsafe, 'Output root mismatch.' unless @run['output_root'] == @store.root
        raise Unsafe, 'Runtime/version differs; start a new run, no silent migration.' unless @run['runtime'] == @host.runtime
        models = @run.fetch('models')
        engines, profiles = @run.values_at('engines', 'profiles')
        raise Unsafe, 'Invalid saved versions/profiles.' unless engines.is_a?(Array) && !engines.empty? && engines == ENGINES.select { |e| engines.include?(e) } && profiles.is_a?(Array) && !profiles.empty? && profiles == PROFILES.select { |p| profiles.include?(p) }
        raise Unsafe, 'Empty or duplicate model list.' if models.empty? || models.map { |r| r['key'] }.uniq.size != models.size
        models.each do |r|
          @catalog.assert_source!(r)
          raise Unsafe, 'Invalid saved version selection.' unless r['exports'].is_a?(Hash) && r['exports'].keys == engines
          raise Unsafe, 'Invalid saved profile selection.' unless r['exports'].values.all? { |records| records.is_a?(Hash) && records.keys == profiles }
        end
      end
      def reverify_existing!
        OvernightBatch.jobs(@run).each do |row, engine, p, r|
          if %w[success reused].include?(r['status'])
            next if @store.valid_record?(r, row, p, @run, @run.fetch('runtime'), engine: engine)
            row['exports'][engine][p] = {'status' => 'pending', 'reuse_reason' => 'needs_verification', 'attempts' => Array(r['attempts'])}
          elsif r['status'] == 'in_progress'
            recovered = recover_attempt(row, engine, p, r)
            if recovered
              row['exports'][engine][p] = recovered
              next
            end
            # No durable validation binding: preserve orphan bytes, retry in a
            # fresh directory. Never adopt a file merely because it exists.
            r['status'] = 'pending'; r['recovery_reason'] = 'interrupted_attempt_not_committed'
          end
        end
      end
      def recover_attempt(row, engine, profile, record)
        path = Array(record['attempts']).last&.fetch('path', nil)
        return nil unless path
        OvernightBatch.existing_safe_file!(path, @store.directory(@run['run_id']))
        receipt_path = "#{path}.batch-validation.json"
        OvernightBatch.existing_safe_file!(receipt_path, @store.root)
        ref = OvernightBatch.fingerprint(receipt_path).merge('path' => receipt_path)
        binding = @store.evidence(ref)
        candidate = record.merge('status' => 'success', 'profile' => profile,
          'format' => FORMATS.fetch(engine), 'engine_wire' => engine, 'engine_display' => engine.upcase,
          'validation' => 'passed', 'runtime' => @run['runtime'], 'path' => path,
          'bytes' => binding.dig('artifact', 'bytes'), 'sha256' => binding.dig('artifact', 'sha256'),
          'performance_receipt' => binding['performance_receipt'], 'validation_receipt' => ref,
          'provenance_receipt' => binding['provenance_receipt'],
          'recovery_reason' => 'verified_commit_after_interruption')
        @store.valid_record?(candidate, row, profile, @run, @run['runtime'], engine: engine) ? candidate : nil
      rescue StandardError
        nil
      end
      def resume
        raise Unsafe, 'Current profile is still draining; wait for its boundary.' if @stepping
        raise Unsafe, 'Run was closed; reload it first.' unless @lock
        verify!; reverify_existing!
        if defined?(ConversionJob) && ConversionJob.active && ConversionJob.active.running?
          raise Unsafe, 'Another interactive conversion is active.'
        end
        SibamboNativeExportLease.acquire(self)
        @cancel_requested = @pause_requested = false; @attempted = {}
        @run.delete('finished_at'); @run.delete('current')
        @run['status'] = 'running'; @store.save(@run)
      end
      def cancel
        @cancel_requested = true
        @run['status'] = @stepping ? 'cancel_requested' : 'cancelled'
        @store.save(@run)
        SibamboNativeExportLease.release(self) unless @stepping
      end
      def pause
        @pause_requested = true
        @run['status'] = @stepping ? 'pause_requested' : 'paused'
        @store.save(@run)
        SibamboNativeExportLease.release(self) unless @stepping
      end
      def counts
        states = OvernightBatch.jobs(@run).map { |_,_,_,record| record['status'] }
        {'completed' => states.count { |s| %w[success reused].include?(s) }, 'failed' => states.count('failed'),
          'cancelled' => states.count('cancelled'), 'pending' => states.count { |s| !%w[success reused failed cancelled].include?(s) }, 'total' => states.size}
      end
      def step(&progress)
        raise Unsafe, 'Reentrant queue step refused.' if @stepping
        perform_step(&progress)
      end
      def perform_step
        return finish('cancelled') if @cancel_requested
        return finish('paused') if @pause_requested
        return counts unless @run['status'] == 'running'
        task = OvernightBatch.jobs(@run).find { |r,e,p,v| !%w[success reused].include?(v['status']) && !@attempted[[r['key'],e,p]] }
        return finish(counts['completed'] == counts['total'] ? 'complete' : 'complete_with_failures') unless task
        row, engine, profile, record = task
        @stepping = true; @attempted[[row['key'],engine,profile]] = true
        source = nil
        begin
          source = @catalog.assert_source!(row)
          raise Unsafe, 'Dirty/unsafe active host; batch paused.' unless @host.safe_to_switch?
          raise Unsafe, 'Insufficient remaining disk space.' unless @host.free_bytes(@store.root) >= MIN_FREE_BYTES + row['bytes']
          base = File.join(@store.directory(@run['run_id']), row['key']); OvernightBatch.unlinked!(base)
          FileUtils.mkdir_p(base, mode: 0o700)
          attempt_dir = File.join(base, "#{engine}-#{profile}-#{SecureRandom.hex(12)}")
          begin
            Dir.mkdir(attempt_dir, 0o700)
          rescue Errno::EEXIST
            raise Unsafe, 'Attempt path collision; output preserved. Investigate before resume.'
          end
          output = OvernightBatch.artifact_path(attempt_dir, engine, profile)
          record['attempts'] ||= []
          record['attempts'] << {'path' => output, 'started_at' => OvernightBatch.timestamp}
          record['status'] = 'in_progress'
          @run['current'] = {'model' => row['relative'], 'engine' => engine, 'profile' => profile, 'stage' => 'OPEN_SKP'}
          @store.save(@run)
          yield @run['current'] if block_given?
          raise Cancelled, 'Cancel before open.' if @cancel_requested
          model = @host.open(source)
          raise Cancelled, 'Cancel after native open, before export.' if @cancel_requested
          @catalog.assert_source!(row)
          result = SibamboNativeExportLease.with_export(self) do
            @host.export(model, output, profile, engine: engine) do |event|
              stage = (event[:stage] || event['stage'] || 'EXPORT').to_s.upcase
              @run['current']['stage'] = stage
              yield @run['current'] if block_given?
              # DONE follows publication. Let its receipt finalize and commit the
              # verified result even if Cancel arrived during native publication.
              raise Cancelled, 'Cancel at safe exporter checkpoint.' if @cancel_requested && stage != 'DONE'
              raise Unsafe, 'Active model changed or became dirty.' unless @host.safe_after_failure?(source)
            end
          end
          @catalog.assert_source!(row)
          raise Unsafe, 'Host identity/dirty state changed.' unless @host.safe_after_failure?(source)
          report = result.dig(:validation, :report)
          raise Unsafe, 'Missing passing fidelity/profile validation.' unless report && report[:passed] == true && report[:profile].to_s == profile
          raise Unsafe, 'Exporter returned a different output path.' unless OvernightBatch.canonical(result.fetch(:path)) == OvernightBatch.canonical(output)
          raise Unsafe, 'Output wire profile failed.' unless @host.validate(output, profile, engine: engine)
          artifact = OvernightBatch.fingerprint(output)
          raise Unsafe, 'Exact must remain strictly below original SKP bytes.' if engine == 'e4' && profile == 'exact' && artifact['bytes'] >= row['bytes']
          performance = OvernightBatch.fingerprint("#{output}.performance.json").merge('path' => "#{output}.performance.json")
          # No rewrite of the exporter's performance receipt: this separate
          # batch-owned binding interoperates without taking receipt-writer files.
          provenance = engine == 'e4' ? nil : OvernightBatch.fingerprint("#{output}.provenance.json").merge('path' => "#{output}.provenance.json")
          binding = {'schema' => 'sibambo-batch-validation-v2', 'engine' => engine, 'profile' => profile,
            'source' => row.slice('bytes','sha256'), 'artifact' => artifact, 'runtime' => @run['runtime'],
            'performance_receipt' => performance, 'provenance_receipt' => provenance,
            'report' => JSON.parse(JSON.generate(report)), 'finished_at' => OvernightBatch.timestamp}
          validation = OvernightBatch.write_new("#{output}.batch-validation.json", binding)
          record.merge!('status' => 'success', 'profile' => profile, 'format' => FORMATS.fetch(engine), 'engine_wire' => engine, 'engine_display' => engine.upcase,
            'validation' => 'passed', 'runtime' => @run['runtime'], 'path' => output, 'bytes' => artifact['bytes'], 'sha256' => artifact['sha256'],
            'performance_receipt' => performance, 'provenance_receipt' => provenance,
            'validation_receipt' => validation, 'finished_at' => OvernightBatch.timestamp)
          raise Unsafe, 'Artifact/receipt validation failed; output retained for investigation.' unless @store.valid_record?(record, row, profile, @run, @run['runtime'], engine: engine)
          @store.save(@run)
        rescue Cancelled => e
          record['status'] = 'cancelled'; record['error'] = "#{e.class}: #{e.message}"; @cancel_requested = true
        rescue StandardError => e
          record['status'] = 'failed'; record['error'] = "#{e.class}: #{e.message}"; record['backtrace'] = Array(e.backtrace).first(20)
          @run['last_error'] = record['error']
          safe = source && @host.safe_after_failure?(source)
          if e.is_a?(Unsafe) || e.is_a?(SystemCallError) || @run['stop_on_error'] || !safe
            @pause_requested = true
          else
            # Continue on error means next MODEL. Other profiles remain pending.
            row['exports'].each { |e, profiles| profiles.each_key { |p| @attempted[[row['key'],e,p]] = true } }
          end
        ensure
          @run.delete('current'); @stepping = false
          @store.save(@run)
          model = result = nil
          GC.start
        end
        return finish('cancelled') if @cancel_requested
        return finish('paused') if @pause_requested
        counts
      rescue StandardError
        @run['status'] = 'paused'
        SibamboNativeExportLease.release(self)
        raise
      end
      private :perform_step
      def finish(state)
        @run['status'] = state; @run.delete('current')
        @run['finished_at'] = OvernightBatch.timestamp if %w[complete complete_with_failures cancelled].include?(state)
        @store.save(@run)
        SibamboNativeExportLease.release(self)
        counts.merge('state' => state)
      end
      def close
        raise Unsafe, 'Cannot abandon a suspended exporter; cancel and drain it first.' if @stepping
        SibamboNativeExportLease.release(self)
        @lock.close if @lock; @lock = nil
      end
    end
  end
end
