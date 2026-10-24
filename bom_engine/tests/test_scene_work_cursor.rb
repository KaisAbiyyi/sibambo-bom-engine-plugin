require 'test/unit'
require_relative '../scene_visibility_resolver'
require_relative '../conversion_job'

class TestSceneWorkCursor < Test::Unit::TestCase
  Cursor = BOMEngine::SceneVisibilityResolver.const_defined?(:WorkCursor) ? BOMEngine::SceneVisibilityResolver::WorkCursor : nil

  def test_time_and_unit_budgets_and_flush
    events = []
    now = 0.0
    cursor = Cursor.new(on_checkpoint: ->(event) { events << event }, clock: -> { now })
    5.times { now += 0.001; cursor.step('scene_index') }
    assert_empty events
    now = 0.006
    cursor.step('scene_index')
    assert_equal({ work_units: 6, operation_label: 'scene_index', force: true }, events.last)
    256.times { cursor.step('scene_overrides') }
    assert_equal 256, events.last[:work_units]
    assert_equal false, events.last[:force], 'unit polling lets the adaptive controller decide whether to yield'
    cursor.flush('scene_occurrences')
    assert_equal 0, events.last[:work_units]
  end

  def test_no_callback_never_reads_clock
    cursor = Cursor.new(on_checkpoint: nil, clock: -> { raise 'clock sampled' })
    300.times { cursor.step('scene_index') }
    assert_nothing_raised { cursor.flush('scene_index') }
  end

  def test_callback_errors_preserve_identity_cause_and_pending_units
    error = RuntimeError.new('observer failed')
    fail_once = true
    events = []
    cursor = Cursor.new(clock: -> { 0.0 }, on_checkpoint: ->(event) {
      if fail_once
        fail_once = false
        raise error
      end
      events << event
    })
    cursor.step('scene_index')
    wrapped = assert_raise(BOMEngine::SceneVisibilityResolver::WorkCursor::CheckpointError) { cursor.flush('scene_index') }
    assert_same error, wrapped.cause
    cursor.flush('scene_index')
    assert_equal 1, events.last[:work_units]
    cancelled = BOMEngine::ConversionJob::Cancelled.new('cancel')
    cursor = Cursor.new(on_checkpoint: ->(_) { raise cancelled })
    assert_same cancelled, assert_raise(BOMEngine::ConversionJob::Cancelled) { cursor.flush('scene_clips') }
  end
end
