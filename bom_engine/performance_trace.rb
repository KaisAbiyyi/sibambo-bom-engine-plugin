# frozen_string_literal: true

# Low-overhead, artifact-independent performance telemetry for conversion work.
# The recorder is deliberately pure Ruby so the same contract can be exercised
# outside SketchUp and disabled without sampling clocks, GC, or memory.

require 'json'
require 'fileutils'
require 'time'

module BOMEngine
  class PerformanceTrace
    SCHEMA = 'sibambo-performance-trace-v1'.freeze
    THREAD_KEY = :__sibambo_performance_trace_v1

    attr_reader :enabled

    class << self
      def current
        Thread.current[THREAD_KEY]
      end

      def with(trace)
        previous = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = trace
        yield trace
      ensure
        Thread.current[THREAD_KEY] = previous
      end

      def stage(name, counts: nil, details: nil, sample_resources: false, &block)
        trace = current
        return yield unless trace && trace.enabled

        trace.stage(name, counts: counts, details: details, sample_resources: sample_resources, &block)
      end

      def increment(name, amount = 1)
        trace = current
        trace.increment(name, amount) if trace && trace.enabled
      end

      def cancellation_error?(error)
        name = error && error.class.name.to_s
        name.match?(/Cancel(?:led|lation)/i)
      end

      def generate_json(receipt)
        JSON.pretty_generate(json_safe(receipt)) + "\n"
      end

      def write_receipt(path, receipt)
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
        temporary = "#{path}.#{Process.pid}.part"
        begin
          File.open(temporary, 'wb') do |file|
            file.write(generate_json(receipt))
            file.flush
            file.fsync rescue nil
          end
          FileUtils.mv(temporary, path, force: true)
        ensure
          File.delete(temporary) if File.file?(temporary)
        end
        path
      end

      def merge_receipt_metadata(path, metadata)
        return nil unless path && File.file?(path)

        payload = JSON.parse(File.read(path, encoding: 'UTF-8'))
        payload['metadata'] = {} unless payload['metadata'].is_a?(Hash)
        payload['metadata'].merge!(json_safe(metadata || {}))
        write_receipt(path, payload)
      end

      def json_safe(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), out| out[key.to_s] = json_safe(child) }
        when Array
          value.map { |child| json_safe(child) }
        when Symbol
          value.to_s
        when Numeric, String, TrueClass, FalseClass, NilClass
          value
        else
          value.to_s
        end
      end
      private :json_safe
    end

    def initialize(enabled: true, clock: nil, cpu_clock: nil, gc_sampler: nil, memory_sampler: nil, metadata: {}, resource_sampling: :root)
      @enabled = enabled == true
      @resource_sampling = resource_sampling.to_s.downcase.to_sym
      raise ArgumentError, "Unknown performance resource sampling mode #{@resource_sampling}." unless [:root, :selected].include?(@resource_sampling)
      @metadata = normalize_hash(metadata).merge(resource_sampling: @resource_sampling.to_s)
      @stages = []
      @counters = Hash.new(0)
      @stack = []
      @next_id = 0
      @finished = false

      return unless @enabled

      @clock = clock || method(:default_wall_clock)
      @cpu_clock = cpu_clock || method(:default_cpu_clock)
      @gc_sampler = gc_sampler || method(:default_gc_snapshot)
      @memory_sampler = memory_sampler || method(:default_memory_snapshot)
      @started_wall = safe_clock(@clock)
      # UTC anchors let an external Windows CPU/RAM/GPU/disk trace be joined to
      # relative monotonic stage times without wall-clock drift assumptions.
      @started_utc = Time.now.utc.iso8601(3)
    end

    def stage(name, counts: nil, details: nil, sample_resources: false)
      return yield unless @enabled
      raise 'Performance trace has already been finalized.' if @finished

      row = {
        id: next_id,
        parent_id: @stack.empty? ? nil : @stack.last[:id],
        name: name.to_s,
        counts: normalize_hash(counts || {}),
        details: normalize_hash(details || {}),
        started_ms: elapsed_from_start_ms,
        status: 'running'
      }
      sample_resources = @stack.empty? || (@resource_sampling == :selected && sample_resources == true)
      row[:_wall_started] = safe_clock(@clock)
      row[:_cpu_started] = safe_clock(@cpu_clock)
      row[:_sample_resources] = sample_resources
      if sample_resources
        row[:_gc_before] = safe_sample(@gc_sampler)
        row[:_memory_before] = safe_sample(@memory_sampler)
      end
      @stages << row
      @stack << row

      begin
        result = yield
        row[:status] = 'success'
        result
      rescue StandardError => error
        row[:status] = cancellation_error?(error) ? 'cancelled' : 'error'
        row[:error_class] = error.class.name.to_s
        row[:error_message] = error.message.to_s
        raise
      ensure
        finalize_stage(row)
        @stack.pop if @stack.last.equal?(row)
      end
    end

    def increment(name, amount = 1)
      return 0 unless @enabled

      key = name.to_sym
      numeric = amount.is_a?(Numeric) ? amount : amount.to_f
      @counters[key] += numeric
    end

    def finish(status:, error: nil, metadata: nil)
      return disabled_receipt(status, error, metadata) unless @enabled

      unless @finished
        @finished = true
        @finished_wall = safe_clock(@clock)
        @finished_utc = Time.now.utc.iso8601(3)
      end
      receipt = {
        schema: SCHEMA,
        enabled: true,
        status: status.to_s,
        total_wall_ms: duration_ms(@started_wall, @finished_wall),
        started_utc: @started_utc,
        finished_utc: @finished_utc,
        metadata: @metadata.merge(normalize_hash(metadata || {})),
        counters: @counters.sort.to_h,
        stages: @stages.map { |row| public_stage(row) }
      }
      if error
        receipt[:error_class] = error.class.name.to_s
        receipt[:error_message] = error.message.to_s
      end
      receipt
    end

    def generate_json(receipt)
      self.class.generate_json(receipt)
    end

    private

    def next_id
      @next_id += 1
      "stage-#{@next_id}"
    end

    def finalize_stage(row)
      wall_finished = safe_clock(@clock)
      cpu_finished = safe_clock(@cpu_clock)
      sample_resources = row.delete(:_sample_resources) == true
      gc_after = sample_resources ? safe_sample(@gc_sampler) : {}
      memory_after = sample_resources ? safe_sample(@memory_sampler) : {}
      row[:duration_ms] = duration_ms(row.delete(:_wall_started), wall_finished)
      cpu_started = row.delete(:_cpu_started)
      row[:cpu_ms] = duration_ms(cpu_started, cpu_finished) if cpu_started && cpu_finished
      row[:gc_delta] = numeric_delta(row.delete(:_gc_before), gc_after)
      row[:memory_delta] = numeric_delta(row.delete(:_memory_before), memory_after)
      row[:finished_ms] = elapsed_from_start_ms(wall_finished)
    end

    def public_stage(row)
      row.each_with_object({}) do |(key, value), out|
        next if key.to_s.start_with?('_')
        next if [:gc_delta, :memory_delta, :counts, :details].include?(key) && value.respond_to?(:empty?) && value.empty?
        out[key] = value
      end
    end

    def disabled_receipt(status, error, metadata)
      receipt = {
        schema: SCHEMA,
        enabled: false,
        status: status.to_s,
        total_wall_ms: nil,
        metadata: @metadata.merge(normalize_hash(metadata || {})),
        counters: {},
        stages: []
      }
      if error
        receipt[:error_class] = error.class.name.to_s
        receipt[:error_message] = error.message.to_s
      end
      receipt
    end

    def elapsed_from_start_ms(now = nil)
      point = now || safe_clock(@clock)
      duration_ms(@started_wall, point)
    end

    def duration_ms(started, finished)
      return nil if started.nil? || finished.nil?
      [((finished.to_f - started.to_f) * 1000.0), 0.0].max.round(3)
    end

    def numeric_delta(before, after)
      return {} unless before.is_a?(Hash) && after.is_a?(Hash)

      after.each_with_object({}) do |(key, value), out|
        previous = before[key] || before[key.to_s]
        next unless value.is_a?(Numeric) && previous.is_a?(Numeric)
        out[key.to_sym] = value - previous
      end
    end

    def safe_clock(callable)
      value = callable.call
      value.nil? ? nil : Float(value)
    rescue StandardError
      nil
    end

    def safe_sample(callable)
      value = callable.call
      value.is_a?(Hash) ? value.dup : {}
    rescue StandardError
      {}
    end

    def default_wall_clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def default_cpu_clock
      return nil unless defined?(Process::CLOCK_PROCESS_CPUTIME_ID)
      Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    rescue StandardError
      nil
    end

    def default_gc_snapshot
      keys = [:count, :major_gc_count, :minor_gc_count, :total_allocated_objects, :total_freed_objects, :heap_live_slots]
      keys.each_with_object({}) do |key, out|
        value = GC.stat(key)
        out[key] = value unless value.nil?
      end
    rescue StandardError
      {}
    end

    def default_memory_snapshot
      result = {}
      [:heap_allocated_pages, :heap_live_slots, :heap_free_slots].each do |key|
        value = GC.stat(key)
        result[key] = value unless value.nil?
      end
      page_size = begin
        GC::INTERNAL_CONSTANTS[:HEAP_PAGE_SIZE]
      rescue StandardError
        nil
      end
      if page_size && result[:heap_allocated_pages]
        result[:heap_bytes_estimate] = result[:heap_allocated_pages].to_i * page_size.to_i
      end
      result
    rescue StandardError
      {}
    end

    def cancellation_error?(error)
      self.class.cancellation_error?(error)
    end

    def normalize_hash(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, child), out|
        out[key.to_sym] = normalize_value(child)
      end
    end

    def normalize_value(value)
      case value
      when Hash then normalize_hash(value)
      when Array then value.map { |child| normalize_value(child) }
      when Symbol then value.to_s
      when Numeric, String, TrueClass, FalseClass, NilClass then value
      else value.to_s
      end
    end
  end
end
