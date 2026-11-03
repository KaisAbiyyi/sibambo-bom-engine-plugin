# frozen_string_literal: true

# An opt-in serial queue for selected SKPs. No SketchUp API is called until the
# operator presses Start/Resume. All receipts remain private on D:.
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'securerandom'
require 'time'

module BOMEngine
  module OvernightBatch
    SCHEMA = 'sibambo-overnight-batch-v1'.freeze
    SOURCE_ROOT = 'D:/projects/sibambo/skps'.freeze
    OUTPUT_ROOT = 'D:/projects/sibambo/private-evidence/batch-exports'.freeze
    PROFILES = %w[exact visual].freeze
    MIN_FREE_BYTES = 512 * 1024 * 1024

    class Unsafe < StandardError; end
    class Cancelled < StandardError; end

    module_function

    def canonical(path)
      File.expand_path(path.to_s).tr('\\', '/').sub(%r{/+\z}, '').downcase
    end

    def within?(path, root)
      child = canonical(path)
      parent = canonical(root)
      child == parent || child.start_with?("#{parent}/")
    end

    def existing_safe_file!(path, root)
      raise Unsafe, 'Output path escapes its private D: run directory.' unless within?(path, root)
      raise Unsafe, 'Output file is missing or is a link.' unless File.file?(path) && !File.symlink?(path)
      raise Unsafe, 'Output resolves outside the private D: run directory.' unless within?(File.realpath(path), File.realpath(root))
      path
    end

    def fingerprint(path)
      raise Unsafe, "Missing source: #{path}" unless File.file?(path) && !File.symlink?(path)
      { 'bytes' => File.size(path), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end

    def timestamp
      Time.now.utc.iso8601(3)
    end

    # A reproducible inventory of the *loaded* Ruby/UI bytes, rather than a
    # claimed RBZ signature. Changes to any runtime file invalidate resume.
    def runtime_identity
      paths = Dir.glob(File.join(__dir__, '**', '*'), File::FNM_DOTMATCH).select do |path|
        File.file?(path) && !File.symlink?(path) && %w[.rb .html .txt].include?(File.extname(path).downcase)
      end.sort
      digest = Digest::SHA256.new
      paths.each do |path|
        digest.update(path.delete_prefix("#{__dir__}/").tr('\\', '/'))
        digest.update("\0")
        digest.update(Digest::SHA256.file(path).digest)
      end
      {
        'files_sha256' => digest.hexdigest,
        'file_count' => paths.length,
        'build_sha' => (defined?(Branding) ? Branding.build_sha : 'unavailable'),
        'engine_wire' => 'e4', 'engine_display' => 'E3', 'format' => 'bomc-1.2',
        'version' => (defined?(Branding) ? Branding::EXTENSION_VERSION : 'unavailable')
      }
    end

    class Catalog
      attr_reader :root, :output_root

      def initialize(root, output_root: OUTPUT_ROOT, require_d: false)
        @root = File.expand_path(root.to_s)
        @output_root = File.expand_path(output_root.to_s)
        raise Unsafe, 'Source root must be an existing readable directory.' unless File.directory?(@root) && File.readable?(@root)
        raise Unsafe, 'Source root cannot be a symbolic link.' if File.symlink?(@root)
        if require_d && (!@root.match?(/\AD:[\\\/]/i) || !@output_root.match?(/\AD:[\\\/]/i))
          raise Unsafe, 'Source and private output must both be on D:.'
        end
        if OvernightBatch.within?(@output_root, @root) || OvernightBatch.within?(@root, @output_root)
          raise Unsafe, 'Private output must be outside the selected SKP source root.'
        end
      end

      def scan
        rows = []
        Find.find(@root) do |path|
          if File.symlink?(path)
            Find.prune if File.directory?(path)
            next
          end
          next unless File.file?(path) && File.extname(path).casecmp('.skp').zero?
          real = File.realpath(path)
          raise Unsafe, 'Source resolves outside the selected root.' unless OvernightBatch.within?(real, @root)
          relative = path.delete_prefix("#{@root}#{File::SEPARATOR}").tr('\\', '/')
          next if relative.empty?
          source = OvernightBatch.fingerprint(path)
          rows << source.merge(
            'relative' => relative,
            'key' => "model-#{Digest::SHA256.hexdigest(relative.downcase)[0, 20]}"
          )
          yield rows.last if block_given?
        end
        rows.sort_by { |row| [row.fetch('relative').downcase, row.fetch('relative')] }
      end

      def assert_source!(row)
        relative = row.fetch('relative')
        path = File.expand_path(relative.tr('/', File::SEPARATOR), @root)
        raise Unsafe, 'Selected path escapes source root.' unless OvernightBatch.within?(path, @root)
        raise Unsafe, 'Selected source is a link or escaped its root.' if File.symlink?(path) || !OvernightBatch.within?(File.realpath(path), @root)
        expected = { 'bytes' => row.fetch('bytes'), 'sha256' => row.fetch('sha256') }
        raise Unsafe, "Source changed: #{relative}" unless OvernightBatch.fingerprint(path) == expected
        path
      end
    end

    class Store
      attr_reader :root

      def initialize(root: OUTPUT_ROOT, profile_checker: nil)
        @root = File.expand_path(root)
        @profile_checker = profile_checker || method(:check_bomc_profile)
      end

      def run_ids
        return [] unless Dir.exist?(@root)
        Dir.children(@root).grep(/\A\d{8}T\d{6}Z-[a-f0-9]{10}\z/).sort.reverse.select do |id|
          Dir.exist?(File.join(@root, id)) && !File.symlink?(File.join(@root, id))
        end
      end

      def load(id)
        raise Unsafe, 'Invalid batch run ID.' unless id.to_s.match?(/\A\d{8}T\d{6}Z-[a-f0-9]{10}\z/)
        directory = File.join(@root, id)
        raise Unsafe, 'Batch run missing or linked.' unless Dir.exist?(directory) && !File.symlink?(directory)
        snapshots = Dir.glob(File.join(directory, 'snapshots', 'state-*.json')).sort.reverse
        snapshots.each do |path|
          next if File.symlink?(path)
          begin
            data = JSON.parse(File.read(path, encoding: 'UTF-8'))
            return data if data['schema'] == SCHEMA && data['run_id'] == id && data['output_root'] == @root
          rescue JSON::ParserError, SystemCallError
            next
          end
        end
        raise Unsafe, 'No valid durable batch snapshot. Manual investigation required.'
      end

      def save(run)
        directory = File.join(@root, run.fetch('run_id'))
        raise Unsafe, 'Cannot persist outside private run directory.' unless OvernightBatch.within?(directory, @root)
        raise Unsafe, 'Missing private run directory.' unless Dir.exist?(directory) && !File.symlink?(directory)
        snapshots = File.join(directory, 'snapshots')
        FileUtils.mkdir_p(snapshots)
        run['sequence'] = run.fetch('sequence', 0) + 1
        run['updated_at'] = OvernightBatch.timestamp
        bytes = JSON.pretty_generate(run) + "\n"
        immutable = File.join(snapshots, format('state-%09d.json', run['sequence']))
        File.open(immutable, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(bytes)
          file.flush
          file.fsync
        end
        current = File.join(directory, 'manifest.json')
        temporary = "#{current}.#{SecureRandom.hex(5)}.part"
        begin
          File.open(temporary, 'wb') { |file| file.write(bytes); file.flush; file.fsync }
          FileUtils.mv(temporary, current, force: true)
        ensure
          File.delete(temporary) if File.file?(temporary)
        end
        run
      end

      def create(catalog:, selected:, profiles:, runtime:, stop_on_error:, free_bytes:)
        raise Unsafe, 'Choose at least one SKP.' if selected.empty?
        raise Unsafe, 'Duplicate SKP selection.' unless selected.uniq.length == selected.length
        raise Unsafe, 'Choose Exact, Visual, or both.' if profiles.empty? || (profiles - PROFILES).any? || profiles.uniq.length != profiles.length
        rows = catalog.scan
        by_relative = rows.to_h { |row| [row.fetch('relative'), row] }
        raise Unsafe, 'Selection is stale; scan again.' unless selected.all? { |relative| by_relative.key?(relative) }
        required = MIN_FREE_BYTES + selected.sum { |relative| by_relative.fetch(relative).fetch('bytes') * 2 }
        raise Unsafe, "Insufficient free D: bytes (need #{required}, available #{free_bytes})." unless free_bytes.is_a?(Integer) && free_bytes >= required
        FileUtils.mkdir_p(@root)
        id = nil
        directory = nil
        8.times do
          candidate = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(5)}"
          begin
            directory = File.join(@root, candidate)
            Dir.mkdir(directory)
            id = candidate
            break
          rescue Errno::EEXIST
            next
          end
        end
        raise Unsafe, 'Cannot reserve unique batch run ID.' unless id
        ordered = selected.map { |relative| by_relative.fetch(relative) }.sort_by { |row| [row.fetch('relative').downcase, row.fetch('relative')] }
        run = {
          'schema' => SCHEMA, 'run_id' => id, 'status' => 'pending', 'sequence' => 0,
          'created_at' => OvernightBatch.timestamp, 'source_root' => catalog.root,
          'output_root' => @root, 'runtime' => runtime, 'stop_on_error' => stop_on_error == true,
          'certified' => false, 'research_qualified' => false,
          'models' => ordered.map do |row|
            profile_rows = profiles.to_h do |profile|
              prior, reason = reusable(row, profile, runtime, catalog.root)
              [profile, prior ? prior.merge('status' => 'reused', 'reused_from' => prior['origin_run']) :
                { 'status' => 'pending', 'reuse_reason' => reason, 'attempts' => [] }]
            end
            row.merge('profiles' => profile_rows)
          end
        }
        save(run)
      end

      def reusable(source, profile, runtime, source_root)
        seen_incomplete = false
        run_ids.each do |id|
          begin
            run = load(id)
            next unless OvernightBatch.canonical(run['source_root']) == OvernightBatch.canonical(source_root)
            row = Array(run['models']).find { |model| model['relative'] == source['relative'] }
            next unless row
            record = (row['profiles'] || {})[profile]
            next unless record
            seen_incomplete = true
            next unless row['bytes'] == source['bytes'] && row['sha256'] == source['sha256']
            next unless run.dig('runtime', 'files_sha256') == runtime['files_sha256']
            next unless valid_record?(record, row, profile, run, runtime)
            return [record.merge('origin_run' => id), 'verified_reuse']
          rescue Unsafe, JSON::ParserError, SystemCallError
            seen_incomplete = true
          end
        end
        [nil, seen_incomplete ? 'needs_verification' : 'no_previous_verified_artifact']
      end

      def valid_record?(record, source, profile, run, runtime)
        return false unless %w[success reused].include?(record['status'])
        return false unless record['format'] == 'bomc-1.2' && record['engine_wire'] == 'e4' && record['engine_display'] == 'E3'
        return false unless record['profile'] == profile && record['validation'] == 'passed'
        return false unless run.dig('runtime', 'files_sha256') == runtime['files_sha256']
        path = OvernightBatch.existing_safe_file!(record['path'], @root)
        receipt = record['performance_receipt'] || {}
        receipt_path = OvernightBatch.existing_safe_file!(receipt.fetch('path'), @root)
        return false unless OvernightBatch.fingerprint(path) == { 'bytes' => record['bytes'], 'sha256' => record['sha256'] }
        return false unless OvernightBatch.fingerprint(receipt_path) == { 'bytes' => receipt['bytes'], 'sha256' => receipt['sha256'] }
        trace = JSON.parse(File.read(receipt_path, encoding: 'UTF-8'))
        metadata = trace.fetch('metadata')
        return false unless trace['schema'] == 'sibambo-performance-trace-v1' && trace['status'] == 'success'
        return false unless metadata['engine'] == 'e4' && metadata['profile'] == profile && metadata['format'] == 'bomc-1.2'
        return false unless metadata.dig('source', 'sha256') == source['sha256'] && metadata.dig('source', 'bytes') == source['bytes']
        return false unless metadata.dig('artifact', 'sha256') == record['sha256'] && metadata.dig('artifact', 'bytes') == record['bytes']
        return false unless @profile_checker.call(path, profile) == true
        true
      rescue KeyError, JSON::ParserError, ArgumentError, SystemCallError, Unsafe
        false
      end

      def check_bomc_profile(path, profile)
        bytes = File.binread(path)
        actual = BOMCExtension.send(:require_active_candidate_profile!, bytes, { profile: profile })
        actual.to_s == profile
      end
    end

    # Production adapter preserves SketchUp's ordinary open prompts and never
    # saves the active model. It runs only on SketchUp's own UI thread.
    class SketchupHost
      def safe_to_switch?
        model = Sketchup.active_model
        model.nil? || (model.respond_to?(:modified?) && !model.modified?)
      end

      def open(path)
        raise Unsafe, 'Active model has unsaved changes; batch paused.' unless safe_to_switch?
        model = Sketchup.active_model
        unless model && OvernightBatch.canonical(model.path) == OvernightBatch.canonical(path)
          raise Unsafe, 'SketchUp refused to open model.' unless Sketchup.open_file(path)
          model = Sketchup.active_model
        end
        raise Unsafe, 'Active SketchUp model identity differs from selected SKP.' unless model && OvernightBatch.canonical(model.path) == OvernightBatch.canonical(path)
        raise Unsafe, 'Selected model became dirty.' unless safe_to_switch?
        model
      end

      def safe_after_failure?(path)
        model = Sketchup.active_model
        model && OvernightBatch.canonical(model.path) == OvernightBatch.canonical(path) && safe_to_switch?
      end

      def export(model, path, profile, &progress)
        raise Unsafe, 'Another conversion is active.' if ConversionJob.active && ConversionJob.active.running?
        BOMCExtension.export(model, output_path: path, profile: profile.to_sym,
          settings: BOMCProcessing.from_ui(batch_mode: 'auto'), progress: progress)
      end

      def validate(path, profile)
        Store.new.check_bomc_profile(path, profile)
      end

      def runtime
        identity = OvernightBatch.runtime_identity
        identity['sketchup_version'] = Sketchup.version.to_s
        identity
      end

      def free_bytes(path)
        require 'fiddle'
        handle = Fiddle.dlopen('kernel32.dll')
        fn = Fiddle::Function.new(handle['GetDiskFreeSpaceExW'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
        directory = File.expand_path(path).tr('/', '\\')
        wide = (directory + "\0").encode('UTF-16LE')
        available = Fiddle::Pointer.malloc(8)
        raise Unsafe, 'Unable to inspect D: free space.' if fn.call(wide, available, 0, 0) == 0
        available[0, 8].unpack1('Q<')
      rescue LoadError, Fiddle::DLError
        raise Unsafe, 'Windows disk-free preflight unavailable.'
      end
    end

    class Queue
      attr_reader :run

      def initialize(store:, catalog:, run:, host:)
        @store, @catalog, @run, @host = store, catalog, run, host
        @cancel_requested = false
        @pause_requested = false
        @attempted = {}
        raise Unsafe, 'Source root does not match batch run.' unless OvernightBatch.canonical(run.fetch('source_root')) == OvernightBatch.canonical(catalog.root)
        raise Unsafe, 'Output root does not match batch run.' unless run.fetch('output_root') == store.root
        raise Unsafe, 'Loaded producer runtime differs from saved batch.' unless run.dig('runtime', 'files_sha256') == host.runtime['files_sha256']
        raise Unsafe, 'SketchUp version differs from saved batch.' unless run.dig('runtime', 'sketchup_version') == host.runtime['sketchup_version']
        run.fetch('models').each { |row| @catalog.assert_source!(row) }
        reverify_existing!
        @run['status'] = 'paused' if @run['status'] == 'running'
        @store.save(@run)
      end

      def reverify_existing!
        @run.fetch('models').each do |row|
          row.fetch('profiles').each do |profile, record|
            next unless %w[success reused].include?(record['status'])
            next if @store.valid_record?(record, row, profile, @run, @run.fetch('runtime'))
            row['profiles'][profile] = { 'status' => 'pending', 'reuse_reason' => 'needs_verification', 'attempts' => Array(record['attempts']) }
          end
        end
      end

      def cancel
        @cancel_requested = true
        @run['status'] = 'cancel_requested' if @run['status'] == 'running'
        @store.save(@run)
      end

      def pause
        @pause_requested = true
        @run['status'] = 'pause_requested' if @run['status'] == 'running'
        @store.save(@run)
      end

      def resume
        raise Unsafe, 'Cannot resume after Cancel without re-verifying run.' if @cancel_requested
        @pause_requested = false
        @attempted = {}
        @run.fetch('models').each { |row| @catalog.assert_source!(row) }
        reverify_existing!
        @run['status'] = 'running'
        @store.save(@run)
      end

      def counts
        statuses = @run.fetch('models').flat_map { |row| row.fetch('profiles').values.map { |v| v['status'] } }
        {
          'completed' => statuses.count { |value| %w[success reused].include?(value) },
          'failed' => statuses.count('failed'), 'cancelled' => statuses.count('cancelled'),
          'pending' => statuses.count { |value| %w[pending in_progress not_run].include?(value) },
          'total' => statuses.length
        }
      end

      def step
        return finish('cancelled') if @cancel_requested
        return finish('paused') if @pause_requested
        task = @run.fetch('models').flat_map do |row|
          row.fetch('profiles').map { |profile, record| [row, profile, record] }
        end.find { |row, profile, record| !%w[success reused].include?(record['status']) && !@attempted[[row['key'], profile]] }
        unless task
          return finish(counts['failed'].positive? ? 'complete_with_failures' : 'complete')
        end
        row, profile, record = task
        @attempted[[row['key'], profile]] = true
        source = @catalog.assert_source!(row)
        model_dir = File.join(@store.root, @run.fetch('run_id'), row.fetch('key'))
        FileUtils.mkdir_p(model_dir)
        attempt = Array(record['attempts']).length + 1
        output = File.join(model_dir, "#{row['key']}__#{profile.upcase}__a#{attempt}.bomc")
        while File.exist?(output)
          attempt += 1
          output = File.join(model_dir, "#{row['key']}__#{profile.upcase}__a#{attempt}.bomc")
        end
        record['attempts'] ||= []
        record['attempts'] << { 'number' => attempt, 'path' => output, 'started_at' => OvernightBatch.timestamp }
        record['status'] = 'in_progress'
        @run['status'] = 'running'
        @run['current'] = { 'model' => row['relative'], 'profile' => profile, 'stage' => 'OPEN_SKP' }
        @store.save(@run)
        yield @run['current'] if block_given?

        begin
          raise Cancelled, 'Batch cancel requested.' if @cancel_requested
          raise Unsafe, 'Another native conversion is running.' if ConversionJob.active && ConversionJob.active.running?
          model = @host.open(source)
          raise Unsafe, 'Source SKP changed after open.' unless @catalog.assert_source!(row)
          result = @host.export(model, output, profile) do |event|
            @run['current']['stage'] = (event[:stage] || event['stage'] || 'EXPORT').to_s
            yield @run['current'] if block_given?
            Fiber.yield if Fiber.current != Fiber.main rescue nil
            raise Cancelled, 'Batch cancel requested.' if @cancel_requested
          end
          raise Unsafe, 'Source SKP changed during export.' unless @catalog.assert_source!(row)
          raise Unsafe, 'Active model changed or became dirty during export.' unless @host.safe_after_failure?(source)
          report = result.dig(:validation, :report)
          raise Unsafe, 'Exporter did not return passing profile validation.' unless report && report[:passed] == true
          raise Unsafe, 'Exporter output/profile failed verification.' unless File.file?(output) && @host.validate(output, profile)
          artifact = OvernightBatch.fingerprint(output)
          receipt_path = BOMCExtension.performance_receipt_path(output)
          raise Unsafe, 'Missing successful performance receipt.' unless File.file?(receipt_path)
          PerformanceTrace.merge_receipt_metadata(receipt_path,
            source: { path: source, bytes: row['bytes'], sha256: row['sha256'] },
            artifact: { path: output, bytes: artifact['bytes'], sha256: artifact['sha256'] },
            engine: 'e4', profile: profile, format: 'bomc-1.2')
          receipt = OvernightBatch.fingerprint(receipt_path)
          record.merge!({
            'status' => 'success', 'profile' => profile, 'format' => 'bomc-1.2',
            'engine_wire' => 'e4', 'engine_display' => 'E3', 'validation' => 'passed',
            'path' => output, 'bytes' => artifact['bytes'], 'sha256' => artifact['sha256'],
            'performance_receipt' => receipt.merge('path' => receipt_path),
            'finished_at' => OvernightBatch.timestamp
          })
          unless @store.valid_record?(record, row, profile, @run, @run.fetch('runtime'))
            raise Unsafe, 'Published profile/receipt did not pass strict reuse verification.'
          end
          @store.save(@run)
          GC.start
        rescue Cancelled => error
          record['status'] = 'cancelled'
          record['error'] = "#{error.class}: #{error.message}"
          @cancel_requested = true
        rescue StandardError => error
          record['status'] = 'failed'
          record['error'] = "#{error.class}: #{error.message}"
          record['backtrace'] = Array(error.backtrace).first(20)
          @run['last_error'] = record['error']
          if error.is_a?(Unsafe) || @run['stop_on_error'] || !@host.safe_after_failure?(source)
            @pause_requested = true
          else
            row.fetch('profiles').each_key do |other|
              @attempted[[row['key'], other]] = true
            end
          end
        ensure
          @run.delete('current')
          @store.save(@run)
        end
        return finish('cancelled') if @cancel_requested
        return finish('paused') if @pause_requested
        counts
      end

      def finish(state)
        @run['status'] = state
        @run.delete('current')
        @run['finished_at'] = OvernightBatch.timestamp if %w[complete complete_with_failures cancelled].include?(state)
        @store.save(@run)
        counts.merge('state' => state)
      end
    end
  end
end
