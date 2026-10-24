# frozen_string_literal: true
# Manual Ruby Console diagnostic. No exporter, adapter or decoder dependencies.
require 'json'
require 'digest'
require 'fileutils'
require 'time'

module SibamboUvReferenceV1
  SCHEMA = 'sibambo-native-uv-reference-v1'
  INPUTS = {
    'D:/projects/sibambo/skps/RUMAH Y.skp' => {
      bytes: 41_785_434, sha256: '5291179e1f4eac5ebf6b5eedc66135469a913f8df6a6d5a28238f497c75af119',
      artifact_sha256: '61b2699ed01b928fccce551f00e04ca1bd9387b315fffb209303e1ec4d03dac8'
    },
    'D:/projects/sibambo/skps/RUMAH I.skp' => {
      bytes: 38_999_997, sha256: '5bca2df092a6c28eca87eaf18584ab7b7519117ebd1dcb5e5c5faee8d77f10d2',
      artifact_sha256: 'f5bae9da30799fb1af25df6f607005fac03946be0b1489b39580386d90c0e4a6'
    }
  }.freeze

  class << self
    attr_reader :active

    def capture(model:, artifact_path:, output_dir:, expected_source_sha256:)
      raise 'A reference capture is already active' if @active
      owner = ENV['SIBAMBO_UV_NATIVE_OWNER'].to_s.strip
      raise 'Operator must attest exclusive native/source ownership with SIBAMBO_UV_NATIVE_OWNER' if owner.empty?
      running = ObjectSpace.each_object(Class).any? do |klass|
        klass.name.to_s.end_with?('::ConversionJob') && klass.respond_to?(:active) && klass.active && klass.active.running?
      end
      raise 'An export job is active' if running
      source = model.path.to_s.tr('\\', '/')
      pin = INPUTS.fetch(source) { raise 'Only the pinned saved Y/I source is eligible' }
      raise 'Source SHA argument differs from the pinned source' unless expected_source_sha256 == pin[:sha256]
      raise 'Model has unsaved changes' if model.modified?
      raise 'Source identity mismatch' unless File.size(source) == pin[:bytes] && Digest::SHA256.file(source).hexdigest == pin[:sha256]
      artifact = File.expand_path(artifact_path).tr('\\', '/')
      raise 'Artifact identity mismatch' unless Digest::SHA256.file(artifact).hexdigest == pin[:artifact_sha256]
      output = output_dir.to_s.tr('\\', '/')
      raise 'Output must be a new absolute D: directory' unless output.match?(/\AD:\//i) && File.expand_path(output).tr('\\', '/') == output && !File.exist?(output)
      @active = Capture.new(model, source, artifact, output, pin, owner)
      @active.start
    rescue StandardError
      @active = nil if @active && !@active.running?
      raise
    end

    def release(capture)
      @active = nil if @active.equal?(capture)
    end
  end

  class Capture
    attr_reader :manifest

    def initialize(model, source, artifact, output, pin, owner)
      @model, @source, @artifact, @output, @pin = model, source, artifact, output, pin
      @manifest = { schema: SCHEMA, complete: false, source_before: source_identity,
        artifact_path: artifact, artifact_sha256: pin[:artifact_sha256], model_guid: model.guid.to_s,
        sketchup_version: Sketchup.version, ruby_version: RUBY_VERSION,
        operator_owner: owner, started_at: Time.now.iso8601, counts: {}, files: {}, max_diagnostic_slice_ms: 0.0 }
      @streams = {}
      @finished = false
      @cancelled = false
      @seen_definitions = {}
      @texture_writer = Sketchup.create_texture_writer
    end

    def running?; !@finished; end
    def cancel; @cancelled = true; end

    def start
      Dir.mkdir(@output) # Exclusive creation; never overwrite a previous receipt.
      @old_temp = [ENV['TEMP'], ENV['TMP']]
      ENV['TEMP'] = ENV['TMP'] = @output
      %w[definitions faces occurrences].each do |name|
        @streams[name] = File.open(File.join(@output, "#{name}.ndjson"), File::WRONLY | File::CREAT | File::EXCL, 0o600)
        @manifest[:counts][name] = 0
      end
      write_manifest
      @started = monotonic
      @fiber = Fiber.new do
        visit_definition(@model, 'root', 'Model Root', 'root')
        visit_occurrences(@model.entities, [], nil, ['root'])
        :complete
      end
      @timer = UI.start_timer(0.001, true) { tick }
      self
    rescue StandardError => error
      finish(false, error)
      raise
    end

    private

    def monotonic; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
    def source_identity; {path: @source, bytes: File.size(@source), sha256: Digest::SHA256.file(@source).hexdigest}; end
    def guard
      raise 'Cancelled by operator' if @cancelled
      raise 'Diagnostic timed out after 30 minutes' if monotonic - @started >= 1800
      raise 'Source model changed during reference capture' unless @model.path.to_s.tr('\\', '/') == @source && !@model.modified? && @model.guid.to_s == @manifest[:model_guid]
    end

    def tick
      return if @finished || @in_tick
      @in_tick = true
      @slice_started = monotonic
      @slice_faces = 0
      begin
        guard
        result = @fiber.resume
        if result == :complete
          guard
          @manifest[:source_after] = source_identity
          raise 'Saved source bytes changed during capture' unless @manifest[:source_after] == @manifest[:source_before]
          raise 'Artifact bytes changed during capture' unless Digest::SHA256.file(@artifact).hexdigest == @pin[:artifact_sha256]
          finish(true)
        end
      rescue StandardError => error
        finish(false, error)
      ensure
        @manifest[:max_diagnostic_slice_ms] = [@manifest[:max_diagnostic_slice_ms], ((monotonic - @slice_started) * 1000).round(3)].max
        write_manifest if @finished
        @in_tick = false
      end
    end

    # Called only after a whole record, including skipped entities, never mid-face.
    def boundary(face: false)
      @slice_faces += 1 if face
      Fiber.yield if @slice_faces >= 64 || monotonic - @slice_started >= 0.006
    end

    def finish(complete, error = nil)
      return if @finished
      @finished = true
      begin
        UI.stop_timer(@timer) if @timer
        @streams.each do |name, io|
          io.flush
          io.close
          @manifest[:files]["#{name}.ndjson"] = Digest::SHA256.file(File.join(@output, "#{name}.ndjson")).hexdigest
        end
        @manifest[:complete] = complete
        @manifest[:error] = {class: error.class.name, message: error.message} if error
        @manifest[:ended_at] = Time.now.iso8601
        write_manifest if Dir.exist?(@output)
      ensure
        @texture_writer = nil
        @fiber = nil
        if @old_temp
          ENV['TEMP'], ENV['TMP'] = @old_temp
        end
        SibamboUvReferenceV1.release(self)
      end
    end

    def write_manifest
      path = File.join(@output, 'manifest.json')
      File.write(path + '.partial', JSON.pretty_generate(@manifest) + "\n")
      File.rename(path + '.partial', path)
    end

    def emit(stream, row)
      @streams.fetch(stream).puts(JSON.generate(row))
      @manifest[:counts][stream] += 1
    end

    def pid(entity); entity.persistent_id.to_s; end
    def point(value); [value.x.to_f, value.y.to_f, value.z.to_f]; end
    def position_projection(value); point(value).map { |x| (x * 0.0254).round(9) }; end
    def material(value)
      return nil unless value
      texture = value.texture
      {native_id: pid(value), name: value.name.to_s,
        texture_pixels: texture ? [texture.image_width, texture.image_height] : nil,
        texture_size_inches: texture ? [texture.width.to_f, texture.height.to_f] : nil}
    end

    def instance?(entity)
      entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
    end

    def definition_identity(entity)
      definition = entity.definition
      group = entity.is_a?(Sketchup::Group)
      [definition, pid(definition), group ? 'group_definition' : 'component_definition',
        group ? (entity.name.to_s.empty? ? '(Group)' : entity.name.to_s) : definition.name.to_s]
    end

    def child_record(entity)
      _definition, id, kind, name = definition_identity(entity)
      {native_id: pid(entity), definition_id: id, kind: kind, exported_name: name,
        transform: entity.transformation.to_a.map(&:to_f),
        projected_transform: entity.transformation.to_a.each_with_index.map { |x, i| (x.to_f * ([12, 13, 14].include?(i) ? 0.0254 : 1.0)).round(9) },
        material: material(entity.material)}
    end

    def visit_definition(definition, id, name, kind)
      return if @seen_definitions[id]
      @seen_definitions[id] = true
      children = []
      definition.entities.each do |entity|
        children << child_record(entity) if instance?(entity)
        boundary
      end
      emit('definitions', {native_id: id, native_name: definition.respond_to?(:name) ? definition.name.to_s : '',
        exported_name: name, kind: kind, children: children})
      definition.entities.each do |entity|
        if entity.is_a?(Sketchup::Face)
          emit('faces', face_record(entity, id))
          boundary(face: true)
        elsif instance?(entity)
          child, child_id, child_kind, child_name = definition_identity(entity)
          visit_definition(child, child_id, child_name, child_kind)
          boundary
        else
          boundary
        end
      end
    end

    def uv_sample(helper, position, side)
      raise helper if helper.is_a?(Exception)
      uvq = side == :front ? helper.get_front_UVQ(position) : helper.get_back_UVQ(position)
      raw = point(uvq)
      raise 'Zero/nonfinite native UVQ' unless raw.all?(&:finite?) && !raw[2].zero?
      {raw_uvq: raw, projected_uv: [(raw[0] / raw[2]).round(9), (raw[1] / raw[2]).round(9)]}
    rescue StandardError => error
      {raw_uvq: raw ? raw.map { |x| x.finite? ? x : x.to_s } : nil,
        error: {class: error.class.name, message: error.message}}
    end

    def face_record(face, owner)
      helper = begin
        face.get_UVHelper(true, true, @texture_writer)
      rescue StandardError => error
        error
      end
      loops = [face.outer_loop] + face.loops.reject(&:outer?)
      mesh = face.mesh
      points = mesh.points
      {definition_id: owner, native_id: pid(face), front_material: material(face.material), back_material: material(face.back_material),
        flags: {front_positioned: face.texture_positioned?(true), back_positioned: face.texture_positioned?(false),
          front_projected: face.texture_projected?(true), back_projected: face.texture_projected?(false)},
        loops: loops.map { |loop| loop.vertices.map { |v| {position_inches: point(v.position), projected_position_m: position_projection(v.position),
          front: uv_sample(helper, v.position, :front), back: uv_sample(helper, v.position, :back)} } },
        triangulation: {polygons: mesh.polygons, points: points.map { |p| {position_inches: point(p), projected_position_m: position_projection(p),
          front: uv_sample(helper, p, :front), back: uv_sample(helper, p, :back)} }} }
    end

    def visit_occurrences(entities, path, inherited, definition_stack)
      entities.each do |entity|
        if instance?(entity)
          definition, id, kind, name = definition_identity(entity)
          current_path = path + [pid(entity)]
          explicit = material(entity.material)
          effective = explicit || inherited
          emit('occurrences', {path: current_path, native_id: pid(entity), definition_id: id, kind: kind, exported_name: name,
            transform: entity.transformation.to_a.map(&:to_f), explicit_material: explicit, inherited_material: inherited,
            effective_front_material: effective, effective_back_material: effective, cycle: definition_stack.include?(id)})
          boundary
          visit_occurrences(definition.entities, current_path, effective, definition_stack + [id]) unless definition_stack.include?(id)
        else
          boundary
        end
      end
    end
  end
end
