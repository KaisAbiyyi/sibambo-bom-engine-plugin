require 'test/unit'
require 'tmpdir'
require_relative '../capture_uv_source_reference'

module UI
  class << self
    attr_reader :callback, :stopped
    def start_timer(_interval, _repeat, &block); @callback = block; @stopped = false; 123; end
    def stop_timer(id); raise 'Wrong owned timer' unless id == 123; @callback = nil; @stopped = true; end
    def tick; @callback.call if @callback; end
  end
end

module Sketchup
  def self.version; 'SDK mock'; end
  def self.create_texture_writer; Object.new; end
  class ComponentInstance; end
  class Group; end
  Point = Struct.new(:x, :y, :z)
  Vertex = Struct.new(:position)
  Loop = Struct.new(:vertices) do
    def outer?; true; end
  end
  class Face
    def initialize(id); @id = id; end
    def persistent_id; @id; end
    def material; nil; end
    def back_material; nil; end
    def texture_positioned?(_side); false; end
    def texture_projected?(_side); false; end
    def points; [Point.new(0,0,0), Point.new(1,0,0), Point.new(0,1,0)]; end
    def outer_loop; Loop.new(points.map { |p| Vertex.new(p) }); end
    def loops; [outer_loop]; end
    def mesh; Struct.new(:points, :polygons).new(points, [[1,2,3]]); end
    def get_UVHelper(front, back, writer)
      raise 'Private writer / both sides required' unless front && back && writer
      self
    end
    def get_front_UVQ(p); Point.new(p.x*2,p.y*2,2); end
    def get_back_UVQ(p); Point.new(p.x*-2,p.y*-2,-2); end
  end
end

class TestCaptureUvSourceReference < Test::Unit::TestCase
  Model = Struct.new(:path, :entities, :changed) do
    def modified?; changed; end
    def guid; 'native-mock-guid'; end
    def name; 'Mock Model'; end
    # No setters, scene selection, model save or transactions are exposed.
  end

  def setup
    @parent = Dir.mktmpdir('uv-reference-', ENV.fetch('TEMP'))
    @source = File.join(@parent, 'source.skp').tr('\\', '/')
    @artifact = File.join(@parent, 'artifact.bomc')
    File.write(@source, 'synthetic source'); File.write(@artifact, 'synthetic artifact')
    @pin = {bytes: File.size(@source), sha256: Digest::SHA256.file(@source).hexdigest, artifact_sha256: Digest::SHA256.file(@artifact).hexdigest}
    @original_pins = SibamboUvReferenceV1::INPUTS
    SibamboUvReferenceV1.send(:remove_const, :INPUTS)
    SibamboUvReferenceV1.const_set(:INPUTS, {@source => @pin}.freeze)
    @old_owner = ENV['SIBAMBO_UV_NATIVE_OWNER']; ENV['SIBAMBO_UV_NATIVE_OWNER'] = 'isolated SDK test'
    @old_temp = [ENV['TEMP'], ENV['TMP']]
    @model = Model.new(@source, 130.times.map { |i| Sketchup::Face.new(i) }, false)
    @out = File.join(@parent, 'reference')
  end

  def teardown
    SibamboUvReferenceV1.active&.cancel
    UI.tick if UI.callback
    SibamboUvReferenceV1.send(:remove_const, :INPUTS)
    SibamboUvReferenceV1.const_set(:INPUTS, @original_pins)
    ENV['SIBAMBO_UV_NATIVE_OWNER'] = @old_owner
    ENV['TEMP'], ENV['TMP'] = @old_temp
    # Keep generated diagnostics on D: for inspection.
  end

  def capture
    SibamboUvReferenceV1.capture(model: @model, artifact_path: @artifact, output_dir: @out, expected_source_sha256: @pin[:sha256])
  end

  def test_read_only_complete_and_bounded_faces
    job = capture
    before = 0
    while job.running?
      UI.tick
      count = job.manifest[:counts]['faces']
      assert_operator count - before, :<=, 64
      before = count
    end
    assert_equal true, job.manifest[:complete]
    assert_equal 130, job.manifest[:counts]['faces']
    assert_equal @pin[:sha256], Digest::SHA256.file(@source).hexdigest
    assert_equal @old_temp, [ENV['TEMP'], ENV['TMP']]
    assert UI.stopped
    assert_nil SibamboUvReferenceV1.active
    row = JSON.parse(File.foreach(File.join(@out, 'faces.ndjson')).first)
    assert_equal [0.0, 0.0, -2.0], row['loops'][0][0]['back']['raw_uvq']
    assert_equal [0.0, 0.0], row['loops'][0][0]['back']['projected_uv']
    assert_equal true, JSON.parse(File.read(File.join(@out, 'manifest.json')))['complete']
  end

  def test_cancel_and_source_mutation_leave_incomplete_closed_receipt
    job = capture
    UI.tick
    job.cancel
    UI.tick
    assert_equal false, job.manifest[:complete]
    assert_match(/Cancelled/, job.manifest[:error][:message])
    assert UI.stopped
    assert_equal @old_temp, [ENV['TEMP'], ENV['TMP']]
    @out += '-mutated'
    job = capture
    @model.changed = true
    UI.tick
    assert_equal false, job.manifest[:complete]
    assert_match(/changed/, job.manifest[:error][:message])
    assert_nil SibamboUvReferenceV1.active
  end

  def test_guards_fail_before_output_and_never_overwrite
    @model.changed = true
    assert_raise(RuntimeError) { capture }
    assert_false File.exist?(@out)
    @model.changed = false
    File.write(@source, 'changed saved bytes')
    assert_raise(RuntimeError) { capture }
    assert_false File.exist?(@out)
  end

  def test_timeout_releases_timer_and_environment
    job = capture
    job.define_singleton_method(:monotonic) { 1_000_000_000.0 }
    UI.tick
    assert_equal false, job.manifest[:complete]
    assert_match(/30 minutes/, job.manifest[:error][:message])
    assert UI.stopped
    assert_equal @old_temp, [ENV['TEMP'], ENV['TMP']]
  end
end
