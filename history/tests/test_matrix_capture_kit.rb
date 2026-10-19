# frozen_string_literal: true
require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require_relative '../../tools/history/build_matrix_capture_kit'
require_relative '../../tools/history/matrix_capture/runner'
require_relative '../../tools/history/matrix_capture/native_reference'

class TestMatrixCaptureKit < Test::Unit::TestCase
  def setup
    @temp = Dir.mktmpdir('matrix-capture-test-')
    @path = File.join(@temp, 'test.skp')
    File.write(@path, 'test source, not runtime evidence')
    @source = { 'path' => @path, 'sha256' => Digest::SHA256.file(@path).hexdigest }
    @model = Struct.new(:path, :modified?).new(@path, false)
  end
  def teardown; FileUtils.remove_entry(@temp); end

  def test_wrong_model_same_name_or_changed_bytes_are_rejected
    other = File.join(@temp, 'other'); Dir.mkdir(other)
    FileUtils.cp(@path, File.join(other, 'test.skp'))
    @model.path = File.join(other, 'test.skp')
    assert_raise(RuntimeError) { SibamboMatrixCapture.validate_model!(@model, @source) }
    @model.path = @path; File.write(@path, 'changed')
    assert_raise(RuntimeError) { SibamboMatrixCapture.validate_model!(@model, @source) }
  end
  def test_modified_model_rejected_and_unchanged_model_allowed
    @model[:modified?] = true
    assert_raise(RuntimeError) { SibamboMatrixCapture.validate_model!(@model, @source) }
    @model[:modified?] = false
    assert_equal true, SibamboMatrixCapture.validate_model!(@model, @source)
  end
  def test_sessions_never_reuse_old_results
    a = SibamboMatrixCapture.reserve_session(@temp)
    assert_not_nil a
    File.write(File.join(a, 'capture_visual.json'), 'old evidence')
    b = SibamboMatrixCapture.reserve_session(@temp)
    assert_not_equal a, b
    assert_equal 'old evidence', File.read(File.join(a, 'capture_visual.json'))
  end
  def test_build_pins_six_sources_and_preserves_historical_kit
    workspace = File.expand_path('../../..', __dir__)
    original = File.join(workspace, 'scratch/t8-capture-kit')
    # This qualification depends on a private local capture kit, source SKP assets,
    # and a separate consumer checkout. None are shipped to a GitHub runner.
    omit 'LOCAL ONLY: original T8 capture kit, SKP corpus and consumer checkout are not in GitHub CI' unless File.file?(File.join(original, 'manifest.json'))
    before = Digest::SHA256.file(File.join(original, 'manifest.json')).hexdigest
    out = File.join(@temp, 'kit')
    result = MatrixCaptureKitBuilder.build(source_kit: original,
      corpus_path: File.join(workspace, 'bom_engine_plugin/bom_engine/benchmarks/evolution-corpus.json'),
      assets_root: File.join(workspace, 'model-eval-old'), consumer_root: File.join(workspace, 'scratch/t0-worktrees-20260907/consumer'), output: out)
    assert_equal 6, result.fetch('jobs', []).length
    assert_equal false, result.fetch('ready')
    assert_true File.file?(File.join(out,'sibambo_matrix_capture_menu.rbz'))
    assert_false result['jobs'].any? { |j| j['source']['path'].include?('RUMAH L') }
    assert_equal before, Digest::SHA256.file(File.join(original, 'manifest.json')).hexdigest
    result['jobs'].each do |job|
      assert_equal job['source']['sha256'], Digest::SHA256.file(job['source']['path']).hexdigest
      assert_true File.file?(File.join(out, job['id'], 'capture_core.rb'))
    end
    assert_raise(RuntimeError) { MatrixCaptureKitBuilder.build(source_kit: original, corpus_path: '', assets_root: '', consumer_root: '', output: out) }
  end
  def test_native_reference_streams_real_fields_and_marks_partial_capture_incomplete
    point = Struct.new(:x, :y, :z) { def to_a; [x,y,z]; end }
    mesh = Struct.new(:points, :polygons) do
      def uv_at(_index, _front); nil; end
    end.new([point.new(0,0,0),point.new(10,0,0),point.new(0,10,0)], [[1,2,3]])
    face = Object.new
    face.define_singleton_method(:typename) { 'Face' }
    face.define_singleton_method(:persistent_id) { 268_435_456 }
    face.define_singleton_method(:mesh) { |_flags| mesh }
    face.define_singleton_method(:area) { 50.0 }
    face.define_singleton_method(:normal) { point.new(0,0,1) }
    face.define_singleton_method(:loops) { [] }
    %i[material back_material layer].each { |m| face.define_singleton_method(m) { nil } }
    face.define_singleton_method(:hidden?) { false }
    model = Struct.new(:entities, :materials, :layers, :pages).new([face], [], [], [])
    path = File.join(@temp,'reference.jsonl'); events=[]
    result=SibamboNativeReference.capture(model,path,source:@source,sketchup_version:'test-double',checkpoint:->(e){events<<e})
    assert_equal 1,result.fetch('faces',0)
    rows=File.readlines(path).map { |line| JSON.parse(line) }
    actual=rows.find { |row| row['kind']=='face' }
    assert_equal '268435456',actual['id']
    assert_in_delta 0.254,actual['points_m'][1][0],1e-12
    assert_in_delta 0.032258,actual['area_m2'],1e-12
    assert_false actual.key?('front_uv'), 'v2 must not repeat incompatible mesh UV measurements'
    assert_equal 'complete',rows.last['status']
    assert_false events.empty?
    assert_raise(Errno::EEXIST) { SibamboNativeReference.capture(model,path,source:@source,sketchup_version:'test',checkpoint:->(_) {}) }
    cancelled=File.join(@temp,'cancelled.jsonl')
    assert_raise(RuntimeError) { SibamboNativeReference.capture(model,cancelled,source:@source,sketchup_version:'test',checkpoint:->(_) {raise 'cancel'}) }
    assert_false File.read(cancelled).include?('"status":"complete"')
  end
  def test_reference_batches_ui_yields_and_preserves_scene_visibility_not_stored
    ignored=Struct.new(:typename,:persistent_id).new('Edge',1)
    camera=Struct.new(:eye,:target,:up).new([0,0,0],[0,1,0],[0,0,1])
    page=Struct.new(:persistent_id,:name,:camera,:hidden_entities,:layers).new(2,'Scene',camera,nil,nil)
    model=Struct.new(:entities,:materials,:layers,:pages).new(Array.new(1000,ignored),[],[],[page])
    events=[]; path=File.join(@temp,'batched.jsonl')
    assert_nothing_raised { SibamboNativeReference.capture(model,path,source:@source,sketchup_version:'test',checkpoint:->(e){events<<e}) }
    assert_operator events.length,:<,20
    scene=File.readlines(path).map { |line| JSON.parse(line) }.find { |r|r['kind']=='scene' }
    assert_nil scene['hidden_entities']
    assert_nil scene['layers']
    footer=JSON.parse(File.readlines(path).last)
    assert_equal({'Edge'=>1000},footer['uncollected_entity_types'])
  end

  def test_native_reference_records_raw_per_loop_uvq_from_uvhelper
    point = Struct.new(:x, :y, :z) { def to_a; [x, y, z]; end }
    vertex = Struct.new(:position)
    loop_type = Struct.new(:vertices) { def outer?; true; end }
    coordinates = [point.new(0, 0, 0), point.new(10, 0, 0), point.new(0, 10, 0)]
    mesh = Struct.new(:points, :polygons) do
      def uv_at(_index, _front); raise 'mesh.uv_at must not run in v2'; end
    end.new(coordinates, [[1, 2, 3]])
    texture = Object.new
    material = Struct.new(:persistent_id, :name, :color, :alpha, :texture).new('mat-1', 'Brick',
      Struct.new(:to_a).new([255, 255, 255, 255]), 1.0, texture)
    texture.define_singleton_method(:filename) { 'brick.jpg' }
    texture.define_singleton_method(:width) { 1.0 }
    texture.define_singleton_method(:height) { 1.0 }
    texture.define_singleton_method(:image_width) { 2 }
    texture.define_singleton_method(:image_height) { 2 }
    helper = Object.new
    helper.define_singleton_method(:get_front_UVQ) { |p| point.new(p.x + 2, p.y + 4, 2) }
    face = Object.new
    face.define_singleton_method(:typename) { 'Face' }
    face.define_singleton_method(:persistent_id) { 42 }
    face.define_singleton_method(:mesh) { |_flags| mesh }
    face.define_singleton_method(:area) { 50.0 }
    face.define_singleton_method(:normal) { point.new(0, 0, 1) }
    face_loop = loop_type.new(coordinates.map { |p| vertex.new(p) })
    face.define_singleton_method(:loops) { [face_loop] }
    face.define_singleton_method(:outer_loop) { face_loop }
    face.define_singleton_method(:material) { material }
    face.define_singleton_method(:back_material) { nil }
    face.define_singleton_method(:layer) { nil }
    face.define_singleton_method(:hidden?) { false }
    face.define_singleton_method(:get_UVHelper) { |_front, _back, _writer| helper }
    model = Struct.new(:entities, :materials, :layers, :pages).new([face], [material], [], [])
    path = File.join(@temp, 'uvq-reference.jsonl')
    SibamboNativeReference.capture(model, path, source: @source, sketchup_version: 'test-double',
      checkpoint: ->(_event) {}, texture_writer: Object.new)
    rows = File.readlines(path).map { |line| JSON.parse(line) }
    assert_equal 't7-native-reference-raw-v2', rows.first['schema_version']
    captured = rows.find { |row| row['kind'] == 'face' }
    assert_equal 'measured', captured.dig('loop_uvq', 'status'), captured['loop_uvq'].inspect
    assert_equal [[2.0, 4.0, 2.0], [12.0, 4.0, 2.0], [2.0, 14.0, 2.0]],
      captured.dig('loop_uvq', 'front_outer')
  end
end
