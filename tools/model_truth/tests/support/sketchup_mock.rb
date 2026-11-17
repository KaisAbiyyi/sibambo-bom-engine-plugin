# frozen_string_literal: true

# Minimal SketchUp API mock: exactly the surface that skp_side.rb is allowed to
# use (plan C4.2). Built from the neutral MTFixture spec so the mock model and
# the hand-built BOMC "decoded" Hash have equal content.

require 'json'
require 'digest'

module UI
  class << self
    attr_reader :callback, :stopped

    def start_timer(_interval, _repeat, &block)
      @callback = block
      @stopped = false
      4242
    end

    def stop_timer(id)
      raise 'wrong timer' unless id == 4242

      @callback = nil
      @stopped = true
    end

    def tick
      @callback&.call
    end

    # Drive ticks until the capture finished (or `max` ticks).
    def run_until(max = 100_000)
      n = 0
      while @callback && n < max
        @callback.call
        n += 1
      end
      n
    end
  end
end

module Sketchup
  class << self
    attr_writer :version, :active_model

    def version
      @version || '26.2.243'
    end

    def platform
      @platform || :platform_win
    end

    attr_writer :platform

    def active_model
      @active_model
    end

    def create_texture_writer
      Object.new
    end
  end

  Point = Struct.new(:x, :y, :z)
  UVQ = Struct.new(:x, :y, :z)

  class Entity
    attr_writer :deleted

    def deleted?
      @deleted ? true : false
    end
  end

  class Color
    attr_reader :red, :green, :blue, :alpha

    def initialize(r, g, b, a)
      @red = r
      @green = g
      @blue = b
      @alpha = a
    end
  end

  class ImageRep
    attr_reader :width, :height, :bits_per_pixel, :row_padding, :data

    def initialize(width = 0, height = 0, bpp = 24, padding = 0, data = ''.b)
      @width = width
      @height = height
      @bits_per_pixel = bpp
      @row_padding = padding
      @data = data
    end

    # Mock encoded file: JSON {"w","h","bgr":[...]} (24 bpp, no padding).
    def load_file(path)
      j = JSON.parse(File.binread(path))
      @width = j['w']
      @height = j['h']
      @bits_per_pixel = 24
      @row_padding = 0
      @data = j['bgr'].pack('C*')
      self
    rescue JSON::ParserError
      raise ArgumentError, 'failed to load image'
    end
  end

  class Texture
    attr_reader :width, :height, :image_width, :image_height

    def initialize(width, height, image_width, image_height, rep_true, rep_false)
      @width = width
      @height = height
      @image_width = image_width
      @image_height = image_height
      @rep_true = rep_true
      @rep_false = rep_false
    end

    def image_rep(colorized = false)
      colorized ? @rep_true : @rep_false
    end
  end

  class Material < Entity
    COLORIZE_SHIFT = 0
    COLORIZE_TINT = 1
    attr_reader :name, :color, :alpha, :materialType, :texture
    attr_accessor :colorize_type, :colorize_deltas

    def initialize(name, color, alpha, type, texture)
      @name = name
      @color = color
      @alpha = alpha
      @materialType = type
      @texture = texture
    end
  end

  class Layer < Entity
    attr_reader :name

    def initialize(name, visible)
      @name = name
      @visible = visible
    end

    def visible?
      @visible
    end
  end

  Vertex = Struct.new(:position)

  class Loop
    def initialize(points, outer)
      @points = points
      @outer = outer
    end

    def vertices
      @points.map { |p| Vertex.new(p) }
    end

    def outer?
      @outer
    end
  end

  class PolygonMesh
    attr_reader :polygons

    def initialize(points, polygons)
      @points = points
      @polygons = polygons
    end

    def point_at(i)
      @points[i - 1]
    end
  end

  class UVHelper
    def initialize(front_uv, back_uv, outer_points)
      @front = front_uv
      @back = back_uv
      @outer = outer_points
    end

    def lookup(uvs, pos)
      idx = @outer.index { |p| p.x == pos.x && p.y == pos.y && p.z == pos.z }
      u, v = uvs[idx]
      UVQ.new(u * 2.0, v * 2.0, 2.0)
    end

    def get_front_UVQ(pos)
      lookup(@front, pos)
    end

    def get_back_UVQ(pos)
      lookup(@back, pos)
    end
  end

  class Face < Entity
    attr_accessor :material, :back_material, :layer, :normal_arr, :hidden, :loops_pts, :tris, :uv_front, :uv_back

    def hidden?
      @hidden ? true : false
    end

    def normal
      Point.new(*@normal_arr)
    end

    def loops
      @loops_pts.each_with_index.map { |pts, i| Loop.new(pts, i.zero?) }
    end

    def outer_loop
      loops.first
    end

    def mesh
      pts = @loops_pts.flatten(1)
      PolygonMesh.new(pts, @tris.map { |t| t.map { |i| i + 1 } })
    end

    def get_UVHelper(front, back, writer)
      raise 'texture writer required' unless writer

      UVHelper.new(front ? @uv_front : nil, back ? @uv_back : nil, @loops_pts.first)
    end
  end

  class Edge < Entity
    attr_accessor :layer, :hidden, :soft, :smooth, :material, :a, :b

    def start
      Vertex.new(@a)
    end

    def end
      Vertex.new(@b)
    end

    def hidden?
      @hidden ? true : false
    end

    def soft?
      @soft ? true : false
    end

    def smooth?
      @smooth ? true : false
    end
  end

  class Transformation
    def initialize(arr)
      @arr = arr
    end

    def to_a
      @arr
    end
  end

  class Instance < Entity
    attr_accessor :definition, :transformation, :material, :layer
  end
  class Group < Instance; end
  class ComponentInstance < Instance; end

  class Image < Entity
    attr_accessor :transformation, :layer
  end

  class Text < Entity
    attr_accessor :text, :point, :layer
  end

  class Entities
    include Enumerable

    def initialize
      @items = []
    end

    def <<(e)
      @items << e
      self
    end

    def each(&block)
      @items.each(&block)
    end
  end

  class ComponentDefinition < Entity
    attr_reader :entities

    def initialize(image = false)
      @entities = Entities.new
      @image = image
    end

    def image?
      @image
    end
  end

  class Model
    attr_accessor :path, :guid, :modified
    attr_reader :entities, :materials, :layers, :definitions

    def initialize
      @entities = Entities.new
      @materials = []
      @layers = []
      @definitions = []
      @modified = false
      @guid = 'MOCK-GUID'
    end

    def modified?
      @modified
    end
  end
end

module SketchupMock
  module_function

  def pt(a)
    Sketchup::Point.new(*a.map(&:to_f))
  end

  def tf(t)
    Sketchup::Transformation.new([1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, t[0].to_f, t[1].to_f, t[2].to_f, 1.0])
  end

  # Builds a model from the MTFixture spec. `skp_path` must exist (SHA check).
  def build(spec, skp_path)
    model = Sketchup::Model.new
    model.path = skp_path
    spec[:tags].each { |t| model.layers << Sketchup::Layer.new(t[:name], t[:visible]) }
    textures = spec[:textures].map do |t|
      rep = Sketchup::ImageRep.new(t[:w], t[:h], 24, 0, t[:bgr_true].pack('C*'))
      rep_false = t[:bgr_false] ? Sketchup::ImageRep.new(t[:w], t[:h], 24, 0, t[:bgr_false].pack('C*')) : rep
      [t, rep, rep_false]
    end
    spec[:materials].each do |m|
      tex = nil
      if m[:texture]
        t, rep, rep_false = textures[m[:texture]]
        tex = Sketchup::Texture.new(m[:tex_w_in], m[:tex_h_in], t[:w], t[:h], rep, rep_false)
      end
      mat = Sketchup::Material.new(m[:name], Sketchup::Color.new(*m[:color]), m[:opacity], m[:type], tex)
      if m[:semantic]
        mat.colorize_type = m[:semantic][:type] == 'shift' ? Sketchup::Material::COLORIZE_SHIFT : Sketchup::Material::COLORIZE_TINT
        mat.colorize_deltas = m[:semantic][:deltas]
      end
      model.materials << mat
    end
    layer = ->(i) { i.nil? ? nil : model.layers[i] }
    material = ->(i) { i.nil? ? nil : model.materials[i] }

    defs = spec[:defs].each_with_index.map do |d, i|
      i.zero? ? nil : Sketchup::ComponentDefinition.new
    end
    spec[:defs].each_with_index do |d, i|
      ents = i.zero? ? model.entities : defs[i].entities
      model.definitions << defs[i] if i.positive?
      d[:faces].each do |f|
        face = Sketchup::Face.new
        face.material = material.call(f[:front])
        face.back_material = material.call(f[:back])
        face.layer = layer.call(f[:tag])
        face.hidden = f[:hidden]
        face.normal_arr = f[:normal].map(&:to_f)
        face.loops_pts = f[:loops].map { |lp| lp.map { |p| pt(p) } }
        face.tris = f[:tris]
        face.uv_front = f[:uv_front]
        face.uv_back = f[:uv_back]
        ents << face
      end
      MTFixture.edge_list(d).each do |e|
        edge = Sketchup::Edge.new
        edge.a = pt(e[:a])
        edge.b = pt(e[:b])
        edge.layer = layer.call(e[:tag])
        edge.hidden = e[:hidden]
        edge.soft = e[:soft]
        edge.smooth = e[:smooth]
        ents << edge
      end
      d[:nodes].each do |n|
        case n[:type]
        when :component, :group
          inst = n[:type] == :group ? Sketchup::Group.new : Sketchup::ComponentInstance.new
          inst.definition = defs[n[:def]]
          inst.transformation = tf(n[:t])
          inst.material = material.call(n[:material])
          inst.layer = layer.call(n[:tag])
          ents << inst
        when :image
          img = Sketchup::Image.new
          img.transformation = tf(n[:t])
          img.layer = layer.call(n[:tag])
          ents << img
        when :text
          txt = Sketchup::Text.new
          txt.text = n[:text]
          txt.point = pt(n[:t])
          txt.layer = layer.call(n[:tag])
          ents << txt
        end
      end
    end
    model
  end
end
