# frozen_string_literal: true
require 'json'
require 'digest'
require 'time'

# Reads SketchUp's native API, not the BOMC encoder/decoder. This raw reference
# still requires an independently reviewed ID/coordinate mapping before fidelity certification.
module SibamboNativeReference
  INCH_TO_M = 0.0254
  def self.vector(value, scale = 1.0)
    return nil if value.nil?
    value.to_a.map do |n|
      raise 'Non-finite native coordinate' unless n.is_a?(Numeric) && n.finite?
      n.to_f * scale
    end
  end
  def self.id(entity); entity&.persistent_id&.to_s; end
  def self.loop_uvq(face, texture_writer)
    front = face.material && face.material.texture
    back = face.back_material && face.back_material.texture
    return { 'status' => 'not_textured' } unless front || back
    return { 'status' => 'unavailable', 'reason' => 'texture_writer_unavailable' } unless texture_writer

    helper = face.get_UVHelper(!!front, !!back, texture_writer)
    outer = face.outer_loop
    holes = face.loops.reject(&:outer?)
    sample = lambda do |loop, side|
      loop.vertices.map do |vertex|
        raw = side == :front ? helper.get_front_UVQ(vertex.position) : helper.get_back_UVQ(vertex.position)
        values = vector(raw)
        raise 'Invalid native UVQ' unless values && values.length == 3
        values
      end
    end
    row = { 'status' => 'measured' }
    if front
      row['front_outer'] = sample.call(outer, :front)
      row['front_holes'] = holes.map { |loop| sample.call(loop, :front) }
    end
    if back
      row['back_outer'] = sample.call(outer, :back)
      row['back_holes'] = holes.map { |loop| sample.call(loop, :back) }
    end
    row
  rescue StandardError => error
    { 'status' => 'unavailable', 'reason' => "#{error.class}: #{error.message}" }
  end

  def self.capture(model, path, source:, sketchup_version:, checkpoint:, texture_writer: nil)
    if texture_writer.nil? && defined?(Sketchup) && Sketchup.respond_to?(:create_texture_writer)
      begin
        texture_writer = Sketchup.create_texture_writer
      rescue StandardError
        texture_writer = nil
      end
    end
    capture_with_writer(model, path, source: source, sketchup_version: sketchup_version,
      checkpoint: checkpoint, texture_writer: texture_writer)
  end

  def self.capture_with_writer(model, path, source:, sketchup_version:, checkpoint:, texture_writer:)
    counts = Hash.new(0)
    uncollected_types = Hash.new(0)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |io|
      emit = ->(row) { io.write(JSON.generate(row)); io.write("\n"); counts[row.fetch('kind')] += 1 }
      emit.call('kind'=>'header', 'schema_version'=>'t7-native-reference-raw-v2', 'source'=>source,
        'sketchup_version'=>sketchup_version, 'captured_at'=>Time.now.utc.iso8601,
        'collector_sha256'=>Digest::SHA256.file(__FILE__).hexdigest,
        'scope'=>'model root and reachable definitions; local coordinates; not a certified oracle',
        'units'=>'m', 'transform_translation_units'=>'inches (native SketchUp matrix)', 'ready'=>false)
      stack = [['root', model.entities]]; visited = {}; processed = 0
      last_yield = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      until stack.empty?
        owner, entities = stack.pop
        entities.each do |entity|
          if processed % 256 == 0 || Process.clock_gettime(Process::CLOCK_MONOTONIC) - last_yield >= 0.02
            checkpoint.call(stage: 'SOURCE_REFERENCE', processed: processed, total: nil)
            last_yield = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
          processed += 1
          common = {'id'=>id(entity), 'owner'=>owner, 'type'=>entity.typename}
          case entity.typename
          when 'Face'
            mesh = entity.mesh(7)
            points = mesh.points
            emit.call(common.merge('kind'=>'face', 'points_m'=>points.map { |p| vector(p, INCH_TO_M) },
              'normal'=>vector(entity.normal), 'area_m2'=>entity.area * INCH_TO_M**2,
              'polygons'=>mesh.polygons, # Signed, one-based indices, preserved verbatim.
              # v1 mesh.uv_at was not comparable with per-loop UVHelper data.
              # Do not pay for two redundant mesh UV passes on every face.
              'loop_uvq'=>loop_uvq(entity, texture_writer),
              'loops'=>entity.loops.map { |loop| {'outer'=>loop.outer?, 'points_m'=>loop.vertices.map { |v| vector(v.position,INCH_TO_M) }} },
              'front_material'=>id(entity.material), 'back_material'=>id(entity.back_material),
              'tag'=>id(entity.layer), 'hidden'=>entity.hidden?))
          when 'Group', 'ComponentInstance'
            definition = entity.definition
            emit.call(common.merge('kind'=>'instance', 'definition'=>id(definition), 'transform'=>vector(entity.transformation),
              'name'=>entity.name, 'tag'=>id(entity.layer), 'material'=>id(entity.material), 'hidden'=>entity.hidden?))
            unless visited[id(definition)]
              visited[id(definition)] = true
              emit.call('kind'=>'definition', 'id'=>id(definition), 'name'=>definition.name)
              stack << [id(definition), definition.entities]
            end
          when 'SectionPlane'
            emit.call(common.merge('kind'=>'section_plane', 'plane_native'=>entity.get_plane.to_a,
              'active'=>entity.active?, 'hidden'=>entity.hidden?))
          else
            counts['uncollected_entity'] += 1 # Never silently claim complete semantic coverage.
            uncollected_types[entity.typename] += 1
          end
        end
      end
      model.materials.each do |m|
        checkpoint.call(stage: 'SOURCE_REFERENCE_MATERIALS', processed: counts.values.sum, total: nil)
        texture = m.texture
        emit.call('kind'=>'material','id'=>id(m),'name'=>m.name,'color'=>m.color.to_a,'alpha'=>m.alpha,
          'texture'=>texture && {'filename'=>texture.filename, 'width'=>texture.width.to_f, 'height'=>texture.height.to_f,
            'image_width'=>texture.image_width, 'image_height'=>texture.image_height})
      end
      model.layers.each { |tag| emit.call('kind'=>'tag','id'=>id(tag),'name'=>tag.name,'visible'=>tag.visible?) }
      model.pages.each do |page|
        checkpoint.call(stage:'SOURCE_REFERENCE_SCENES',processed:counts.values.sum,total:nil)
        camera=page.camera
        emit.call('kind'=>'scene','id'=>id(page),'name'=>page.name,'eye_m'=>vector(camera.eye,INCH_TO_M),
          'target_m'=>vector(camera.target,INCH_TO_M),'up'=>vector(camera.up),
          'hidden_entities'=>page.hidden_entities&.map { |e| id(e) }, 'layers'=>page.layers&.map { |e| id(e) })
      end
      emit.call('kind'=>'footer','status'=>'complete','counts'=>counts.dup,
        'uncollected_entity_types'=>uncollected_types.sort.to_h,'ready'=>false)
    end
    {'faces'=>counts['face'],'counts'=>counts,'path'=>path,'sha256'=>Digest::SHA256.file(path).hexdigest,'ready'=>false}
  end
end
