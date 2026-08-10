# frozen_string_literal: true

require 'json'
require 'minitest/autorun'

module UI
  class HtmlDialog
    STYLE_DIALOG = 0 unless const_defined?(:STYLE_DIALOG)

    attr_reader :file, :scripts

    def initialize(**_options)
      @callbacks = {}
      @scripts = []
      @closed = false
      UI.dialogs << self
    end

    def set_file(path)
      @file = path
    end

    def add_action_callback(name, &callback)
      @callbacks[name.to_s] = callback
    end

    def set_on_closed(&callback)
      @on_closed = callback
    end

    def execute_script(script)
      @scripts << script
    end

    def show
      @shown = true
    end

    def close
      return if @closed

      @closed = true
      @on_closed.call if @on_closed
    end

    def trigger(name, *arguments)
      @callbacks.fetch(name.to_s).call(nil, *arguments)
    end

    def shown?
      @shown == true
    end

    def closed?
      @closed
    end
  end

  class << self
    attr_reader :dialogs, :messages

    def reset_clean_batch_fakes!
      @dialogs = []
      @messages = []
      @timers = {}
      @next_timer_id = 0
    end

    def start_timer(_interval, _repeat, &callback)
      @next_timer_id += 1
      @timers[@next_timer_id] = callback
      @next_timer_id
    end

    def stop_timer(timer_id)
      @timers.delete(timer_id)
    end

    def tick
      @timers.values.dup.each(&:call)
    end

    def messagebox(message, *_arguments)
      @messages << message
    end
  end

  reset_clean_batch_fakes!
end

require_relative '../clean_analysis'

class CleanAnalysisBatchingTest < Minitest::Test
  def setup
    UI.reset_clean_batch_fakes!
  end

  def test_batch_options_require_an_explicit_choice_before_starting
    options = defined?(BOMEngine::CleanAnalysis::BatchOptions) &&
              BOMEngine::CleanAnalysis::BatchOptions
    assert options, 'clean analysis batch options are not loaded'

    selections = []
    dialog = options.show(
      profile: { cores: 8, recommended_batch: 24, calibration_iterations: 100 }
    ) do |batch_size, mode, pretty_print|
      selections << [batch_size, mode, pretty_print]
    end

    assert dialog.shown?
    assert_empty selections
    dialog.trigger('ready')
    dialog.trigger('start', JSON.generate(mode: 'manual', batch_size: 8))

    assert_equal [[8, 'manual', false]], selections
    assert dialog.closed?
  end

  def test_batch_options_pass_the_pretty_print_selection_to_the_export
    selections = []
    dialog = BOMEngine::CleanAnalysis::BatchOptions.show(
      profile: { cores: 8, recommended_batch: 24, calibration_iterations: 100 }
    ) do |batch_size, mode, pretty_print|
      selections << [batch_size, mode, pretty_print]
    end

    dialog.trigger(
      'start',
      JSON.generate(mode: 'auto', batch_size: 8, pretty_print: true)
    )

    assert_equal [[24, 'auto', true]], selections
  end

  def test_batch_recommendations_match_the_existing_engine_profiles
    options = BOMEngine::CleanAnalysis::BatchOptions

    assert_equal 8, options.recommended_batch(cores: 2, calibration_iterations: 100)
    assert_equal 16, options.recommended_batch(cores: 4, calibration_iterations: 100)
    assert_equal 24, options.recommended_batch(cores: 8, calibration_iterations: 100)
    assert_equal 64, options.recommended_batch(cores: 16, calibration_iterations: 100)
    assert_equal 96, options.recommended_batch(cores: 24, calibration_iterations: 100)
    assert_equal 8_192, options.normalize_batch(8_192, fallback: 24)
    assert_equal 24, options.normalize_batch(999, fallback: 24)
  end

  def test_conversion_job_yields_between_work_slices_and_rejects_a_second_job
    job_class = defined?(BOMEngine::CleanAnalysis::ConversionJob) &&
                BOMEngine::CleanAnalysis::ConversionJob
    assert job_class, 'clean analysis cooperative conversion job is not loaded'

    processed = []
    job = job_class.start(
      title: 'Clean export',
      output_path: 'C:/tmp/clean.json',
      batch_size: 8
    ) do |progress|
      3.times do |index|
        processed << index
        progress.call(stage: 'Extracting', processed: index + 1)
      end
      {
        path: 'C:/tmp/clean.json',
        bytes: 10,
        counts: {
          'architectural_surface_count' => 1,
          'component_count' => 0,
          'excluded_object_count' => 0
        }
      }
    end

    second_work_ran = false
    duplicate = job_class.start(title: 'Duplicate', output_path: 'C:/tmp/duplicate.json') do
      second_work_ran = true
    end

    assert_same job, duplicate
    refute second_work_ran
    assert_empty processed
    UI.tick
    assert_equal [0], processed
    assert job.running?, UI.dialogs.first.scripts.inspect

    5.times { UI.tick if job.running? }

    refute job.running?
    refute second_work_ran
    assert_nil job_class.active
    assert_equal 1, UI.messages.length
  end

  def test_progress_batcher_yields_on_time_budget_before_a_large_item_batch_is_full
    now = 0.0
    events = []
    batcher = nil
    error = nil

    begin
      batcher = BOMEngine::CleanAnalysis::ProgressBatcher.new(
        ->(event) { events << event },
        8_192,
        clock: -> { now },
        max_slice_seconds: 0.08
      )
    rescue ArgumentError => caught
      error = caught
    end

    assert_nil error
    batcher.step('Extracting polygon fragments')
    assert_empty events
    now = 0.081
    batcher.step('Extracting polygon fragments')

    assert_equal [
      { stage: 'Extracting polygon fragments', processed: 2 }
    ], events
  end
end
