# frozen_string_literal: true
require 'json'
require 'digest'
require 'securerandom'
require 'fileutils'

# Isolated Exact test runner. The snapshot's native extension menus are not
# registered; this runner is invoked explicitly from the Ruby Console.
module SibamboExactPreparedCapture
  def self.configure(root, engine)
    raise 'An Exact test is already running' if @running
    @root, @engine = root, engine
  end

  def self.start
    raise 'An Exact test is already running' if @running
    raise 'SketchUp 2026 runtime required' unless defined?(Sketchup) && defined?(UI)
    raise 'Capture runner is not configured' unless @root && @engine
    manifest = JSON.parse(File.read(File.join(@root, 'manifest.json')))
    raise 'This kit is not a prepared Exact capture' unless manifest['schema'] == 'prepared-exact-full-kit-v1' && manifest['ready'] == false
    manifest.fetch('files').each do |relative, expected|
      file = File.join(@root, relative)
      raise "Capture kit changed: #{relative}" unless File.file?(file) && Digest::SHA256.file(file).hexdigest == expected
    end
    evidence = manifest.fetch('evidence')
    offline = evidence.fetch('offline_report')
    browser = evidence.fetch('browser_report')
    raise 'Prepared texture report changed' unless Digest::SHA256.file(offline).hexdigest == evidence.fetch('offline_report_sha256')
    raise 'Browser proof changed' unless Digest::SHA256.file(browser).hexdigest == evidence.fetch('browser_report_sha256')
    model = Sketchup.active_model
    raise 'Open the captured, saved model without unsaved changes' unless model && File.file?(model.path.to_s) && !model.modified?
    source_path = File.realpath(model.path).tr('\\', '/').downcase
    expected_path = File.realpath(evidence.fetch('source_path')).tr('\\', '/').downcase
    raise 'Open the source model used for the pixel capture' unless source_path == expected_path
    raise 'Source SKP changed since pixel capture' unless Digest::SHA256.file(model.path).hexdigest == evidence.fetch('source_sha256')

    require_relative 'bom_engine/bomc_extension'
    require_relative 'bom_engine/bomc_prepared_color_maps'
    prepared = @engine::BOMCPreparedColorMaps.load(offline_report: offline, browser_report: browser)
    @model = model
    @source_sha = evidence.fetch('source_sha256')
    @session = File.join(@root, 'results', "capture-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@session)
    output = File.join(@session, 'candidate-exact.bomc')
    @report = {'schema' => 'prepared-exact-full-capture-v1', 'status' => 'running', 'ready' => false,
      'source_tree_sha256' => manifest.fetch('source_tree_sha256'),
      'source_path' => model.path, 'source_sha256' => @source_sha,
      'source_bytes' => File.size(model.path), 'required_loader' => 'bomc-next-jcm-v1'}
    save_report
    @running = true
    @engine::ConversionJob.start(title: 'Sibambo E4 Exact prepared test — not certified',
      output_path: output, batch_size: 512) do |progress|
      begin
        checked_progress = lambda do |event|
          raise 'Active model changed during Exact test' unless Sketchup.active_model.equal?(@model) && !@model.modified?
          progress.call(event)
        end
        result = @engine::BOMCExtension.export(model, output_path: output, profile: :exact,
          progress: checked_progress, allow_jpeg_color_map: true, prepared_color_maps: prepared)
        raise 'Saved source changed during Exact test' unless Digest::SHA256.file(model.path).hexdigest == @source_sha
        unless result[:bytes].is_a?(Integer) && result[:bytes] < @report.fetch('source_bytes') &&
            result.dig(:validation, :report, :passed) == true && File.file?(output)
          raise 'Exact test did not pass size and profile gates'
        end
        @report['status'] = 'captured_pending_certification'
        @report['candidate_file'] = File.basename(output)
        @report['candidate_bytes'] = File.size(output)
        @report['candidate_sha256'] = Digest::SHA256.file(output).hexdigest
        @report['source_savings_bytes'] = @report.fetch('source_bytes') - @report.fetch('candidate_bytes')
        save_report
        result
      rescue StandardError => error
        @report['status'] = 'failed'
        @report['error'] = "#{error.class}: #{error.message}"
        save_report
        raise
      ensure
        @running = false
      end
    end
    puts "Prepared Exact test started: #{@session}; ready=false"
    @session
  end

  def self.save_report
    File.write(File.join(@session, 'report.json'), JSON.pretty_generate(@report))
  end
end
