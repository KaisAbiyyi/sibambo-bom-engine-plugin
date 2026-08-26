# frozen_string_literal: true
# Mock SketchUp environment for headless testing outside SketchUp.

module Geom
  class Point3d
    attr_accessor :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      if x.is_a?(Array)
        @x = x[0].to_f
        @y = x[1].to_f
        @z = x[2].to_f
      elsif x.is_a?(Point3d)
        @x = x.x.to_f
        @y = x.y.to_f
        @z = x.z.to_f
      else
        @x = x.to_f
        @y = y.to_f
        @z = z.to_f
      end
    end

    def to_a
      [@x, @y, @z]
    end

    def +(other)
      Point3d.new(@x + other.x, @y + other.y, @z + other.z)
    end

    def -(other)
      if other.is_a?(Point3d)
        Vector3d.new(@x - other.x, @y - other.y, @z - other.z)
      else
        Point3d.new(@x - other.x, @y - other.y, @z - other.z)
      end
    end

    def ==(other)
      other.respond_to?(:x) && (@x - other.x).abs < 1e-6 && (@y - other.y).abs < 1e-6 && (@z - other.z).abs < 1e-6
    end

    def inspect
      "Point3d(#{@x}, #{@y}, #{@z})"
    end
  end

  class Vector3d
    attr_accessor :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      if x.is_a?(Array)
        @x = x[0].to_f
        @y = x[1].to_f
        @z = x[2].to_f
      elsif x.is_a?(Vector3d)
        @x = x.x.to_f
        @y = x.y.to_f
        @z = x.z.to_f
      else
        @x = x.to_f
        @y = y.to_f
        @z = z.to_f
      end
    end

    def to_a
      [@x, @y, @z]
    end

    def length
      Math.sqrt(@x * @x + @y * @y + @z * @z)
    end

    def normalize
      len = length
      len.zero? ? Vector3d.new(0, 0, 0) : Vector3d.new(@x / len, @y / len, @z / len)
    end

    def dot(other)
      @x * other.x + @y * other.y + @z * other.z
    end

    def cross(other)
      nx = @y * other.z - @z * other.y
      ny = @z * other.x - @x * other.z
      nz = @x * other.y - @y * other.x
      Vector3d.new(nx, ny, nz)
    end

    def reverse!
      @x = -@x
      @y = -@y
      @z = -@z
      self
    end

    def transform(tf)
      tf * self
    end

    def *(arg)
      if arg.is_a?(Vector3d)
        cross(arg)
      elsif arg.is_a?(Numeric)
        Vector3d.new(@x * arg, @y * arg, @z * arg)
      else
        cross(arg)
      end
    end

    def parallel?(other)
      v1 = normalize
      v2 = other.normalize
      (v1.dot(v2).abs - 1.0).abs < 1e-5
    end

    def inspect
      "Vector3d(#{@x}, #{@y}, #{@z})"
    end
  end

  class Transformation
    attr_accessor :matrix

    def initialize(arg = nil)
      if arg.is_a?(Array) && arg.length == 16
        @matrix = arg.map(&:to_f)
      else
        @matrix = [
          1.0, 0.0, 0.0, 0.0,
          0.0, 1.0, 0.0, 0.0,
          0.0, 0.0, 1.0, 0.0,
          0.0, 0.0, 0.0, 1.0
        ]
      end
    end

    def to_a
      @matrix.dup
    end

    def self.translation(arg)
      t = new
      if arg.is_a?(Array) || arg.is_a?(Vector3d) || arg.is_a?(Point3d)
        arr = arg.to_a
        t.matrix[12] = arr[0].to_f
        t.matrix[13] = arr[1].to_f
        t.matrix[14] = arr[2].to_f
      end
      t
    end

    def self.scaling(sx, sy = nil, sz = nil)
      sy ||= sx
      sz ||= sx
      t = new
      t.matrix[0] = sx.to_f
      t.matrix[5] = sy.to_f
      t.matrix[10] = sz.to_f
      t
    end

    def *(other)
      if other.is_a?(Point3d)
        m = @matrix
        x = other.x * m[0] + other.y * m[4] + other.z * m[8] + m[12]
        y = other.x * m[1] + other.y * m[5] + other.z * m[9] + m[13]
        z = other.x * m[2] + other.y * m[6] + other.z * m[10] + m[14]
        Point3d.new(x, y, z)
      elsif other.is_a?(Vector3d)
        m = @matrix
        x = other.x * m[0] + other.y * m[4] + other.z * m[8]
        y = other.x * m[1] + other.y * m[5] + other.z * m[9]
        z = other.x * m[2] + other.y * m[6] + other.z * m[10]
        Vector3d.new(x, y, z)
      else
        m1 = @matrix
        m2 = other.to_a
        res = Array.new(16, 0.0)
        4.times do |i|
          4.times do |j|
            sum = 0.0
            4.times do |k|
              sum += m1[k * 4 + i] * m2[j * 4 + k]
            end
            res[j * 4 + i] = sum
          end
        end
        Transformation.new(res)
      end
    end
  end

  class BoundingBox
    attr_accessor :min, :max

    def initialize
      @min = Point3d.new(0, 0, 0)
      @max = Point3d.new(0, 0, 0)
      @empty = true
    end

    def add(point)
      p = point.is_a?(Point3d) ? point : Point3d.new(point)
      if @empty
        @min = Point3d.new(p.x, p.y, p.z)
        @max = Point3d.new(p.x, p.y, p.z)
        @empty = false
      else
        @min.x = [@min.x, p.x].min
        @min.y = [@min.y, p.y].min
        @min.z = [@min.z, p.z].min
        @max.x = [@max.x, p.x].max
        @max.y = [@max.y, p.y].max
        @max.z = [@max.z, p.z].max
      end
    end

    def valid?
      !@empty
    end

    def center
      Point3d.new((@min.x + @max.x) / 2.0, (@min.y + @max.y) / 2.0, (@min.z + @max.z) / 2.0)
    end

    def width
      @max.x - @min.x
    end

    def height
      @max.y - @min.y
    end

    def depth
      @max.z - @min.z
    end
  end
end

module Sketchup
  class Color
    attr_accessor :red, :green, :blue, :alpha

    def initialize(r = 0, g = 0, b = 0, a = 255)
      @red = r
      @green = g
      @blue = b
      @alpha = a
    end
  end

  class Layer
    attr_accessor :name, :visible, :page_behavior, :folder, :persistent_id

    def initialize(name = 'Layer0')
      @name = name
      @visible = true
      @page_behavior = 0x0000
      @folder = nil
      @persistent_id = "pid_#{name.downcase}"
    end

    def visible?
      @visible
    end
  end

  class Entity
    attr_accessor :persistent_id, :entityID, :hidden, :attributes
    attr_writer :layer

    def initialize
      @persistent_id = object_id.to_s
      @entityID = object_id
      @layer = nil
      @hidden = false
      @deleted = false
      @attributes = {}
    end

    def layer
      @layer || (defined?(Sketchup) && Sketchup.respond_to?(:active_model) && Sketchup.active_model && Sketchup.active_model.layers ? Sketchup.active_model.layers.first : nil)
    end

    def deleted?
      @deleted
    end

    def erase!
      @deleted = true
    end

    def hidden?
      @hidden
    end

    def visible?
      !@hidden
    end

    def attribute_dictionaries
      @attributes
    end

    def get_attribute(dict, key, default = nil)
      (@attributes[dict] || {})[key] || default
    end

    def set_attribute(dict, key, value)
      @attributes[dict] ||= {}
      @attributes[dict][key] = value
    end
  end

  class Drawingelement < Entity
    attr_accessor :material
  end

  class Image < Drawingelement; end
  class Text < Drawingelement; end
  class Dimension < Drawingelement; end

  class Loop
    attr_accessor :vertices, :is_outer

    def initialize(vertices = [], is_outer = true)
      @vertices = vertices
      @is_outer = is_outer
    end

    def outer?
      @is_outer
    end
  end

  class Vertex
    attr_accessor :position

    def initialize(position)
      @position = position.is_a?(Geom::Point3d) ? position : Geom::Point3d.new(position)
    end
  end

  class PolygonMesh
    attr_accessor :points, :polygons

    def initialize
      @points = []
      @polygons = []
    end

    def add_point(pt)
      p = pt.is_a?(Geom::Point3d) ? pt : Geom::Point3d.new(pt)
      existing = @points.index { |pt_item| pt_item == p }
      return existing + 1 if existing

      @points << p
      @points.length
    end

    def add_polygon(*indices)
      @polygons << indices.flatten
    end

    def point_at(index)
      @points[index - 1]
    end
  end

  class Face < Drawingelement
    attr_accessor :material, :back_material, :loops, :normal, :points

    def initialize(points = [])
      super()
      @points = points.map { |p| p.is_a?(Geom::Point3d) ? p : Geom::Point3d.new(p) }
      @vertices = @points.map { |p| Vertex.new(p) }
      @loops = [Loop.new(@vertices, true)]
      @material = nil
      @back_material = nil
      @normal = compute_normal
    end

    def outer_loop
      @loops.find(&:outer?) || @loops.first
    end

    def vertices
      @vertices
    end

    def mesh
      pm = PolygonMesh.new
      outer = outer_loop
      outer_pts = outer ? outer.vertices.map(&:position) : @points
      holes = @loops.reject(&:outer?)

      if holes.empty?
        indices = outer_pts.map { |pt| pm.add_point(pt) }
        pm.add_polygon(indices[0], indices[1], indices[2])
        if indices.length >= 4
          pm.add_polygon(indices[0], indices[2], indices[3])
        end
      else
        # Triangulate polygon with hole
        outer_idx = outer_pts.map { |pt| pm.add_point(pt) }
        hole_idx = holes.first.vertices.map { |v| pm.add_point(v.position) }
        # Triangles around the 4-sided hole inside 4-sided outer
        # (O0, O1, H1), (O0, H1, H0), (O1, O2, H2), (O1, H2, H1),
        # (O2, O3, H3), (O2, H3, H2), (O3, O0, H0), (O3, H0, H3)
        4.times do |i|
          next_i = (i + 1) % 4
          pm.add_polygon(outer_idx[i], outer_idx[next_i], hole_idx[next_i])
          pm.add_polygon(outer_idx[i], hole_idx[next_i], hole_idx[i])
        end
      end
      pm
    end

    def area(tf = nil)
      pts = if tf
              @points.map { |p| tf * p }
            else
              @points
            end
      return 0.0 if pts.length < 3
      vector = [0.0, 0.0, 0.0]
      pts.each_with_index do |current, i|
        following = pts[(i + 1) % pts.length]
        vector[0] += (current.y - following.y) * (current.z + following.z)
        vector[1] += (current.z - following.z) * (current.x + following.x)
        vector[2] += (current.x - following.x) * (current.y + following.y)
      end
      0.5 * Math.sqrt(vector[0]**2 + vector[1]**2 + vector[2]**2)
    end

    def get_UVHelper(front, back, tw)
      UVHelper.new
    end

    private

    def compute_normal
      return Geom::Vector3d.new(0, 0, 1) if @points.length < 3
      v1 = @points[1] - @points[0]
      v2 = @points[2] - @points[0]
      nx = v1.y * v2.z - v1.z * v2.y
      ny = v1.z * v2.x - v1.x * v2.z
      nz = v1.x * v2.y - v1.y * v2.x
      Geom::Vector3d.new(nx, ny, nz).normalize
    end
  end

  class UVHelper
    def get_front_UVQ(pt)
      Geom::Vector3d.new(0.0, 0.0, 1.0)
    end

    def get_back_UVQ(pt)
      Geom::Vector3d.new(0.0, 0.0, 1.0)
    end
  end

  class Edge < Drawingelement
    attr_accessor :start, :end, :soft, :smooth

    def initialize(p1, p2)
      super()
      @start = Vertex.new(p1)
      @end = Vertex.new(p2)
      @soft = false
      @smooth = false
    end

    def soft?
      @soft
    end

    def smooth?
      @smooth
    end

    def length
      (@start.position - @end.position).length
    end
  end

  class Entities
    include Enumerable

    def initialize(parent = nil)
      @parent = parent
      @items = []
    end

    def each(&block)
      @items.reject(&:deleted?).each(&block)
    end

    def [](index)
      @items.reject(&:deleted?)[index]
    end

    def length
      @items.reject(&:deleted?).length
    end

    def size
      length
    end

    def parent
      @parent
    end

    def add_group
      g = Group.new(self)
      @items << g
      g
    end

    def add_instance(definition, transformation)
      inst = ComponentInstance.new(definition, transformation, self)
      @items << inst
      definition.instances << inst
      inst
    end

    def add_face(*args)
      pts = if args.length == 1 && args[0].is_a?(Array) && (args[0][0].is_a?(Array) || args[0][0].is_a?(Geom::Point3d))
              args[0]
            else
              args
            end
      # Check if this is an inner face within an existing face in this definition
      existing_outer = @items.find { |item| item.is_a?(Face) && !item.deleted? }
      first_x = pts[0].is_a?(Array) ? pts[0][0] : (pts[0].respond_to?(:x) ? pts[0].x : 0)
      if existing_outer && pts.length >= 3 && first_x > 0
        inner_vertices = pts.map { |p| Vertex.new(p) }
        existing_outer.loops << Loop.new(inner_vertices, false)
      end
      face = Face.new(pts)
      @items << face
      face
    end

    def add_edge(p1, p2)
      edge = Edge.new(p1, p2)
      @items << edge
      edge
    end
  end

  class Group < Drawingelement
    attr_accessor :name, :description, :entities, :transformation, :definition

    def initialize(parent = nil)
      super()
      @name = ''
      @description = ''
      @entities = Entities.new(self)
      @transformation = Geom::Transformation.new
      @definition = ComponentDefinition.new('GroupDef', @entities)
    end

    def bounds
      bb = Geom::BoundingBox.new
      bb.add([0, 0, 0])
      bb.add([10, 10, 10])
      bb
    end
  end

  class ComponentDefinition
    attr_accessor :name, :description, :guid, :entities, :instances

    def initialize(name = 'Component', entities = nil)
      @name = name
      @description = ''
      @guid = "guid_#{object_id}"
      @entities = entities || Entities.new(self)
      @instances = []
    end

    def bounds
      bb = Geom::BoundingBox.new
      bb.add([0, 0, 0])
      bb.add([10, 10, 10])
      bb
    end
  end

  class ComponentInstance < Drawingelement
    attr_accessor :name, :definition, :transformation

    def initialize(definition, transformation = nil, parent = nil)
      super()
      @name = ''
      @definition = definition
      @transformation = transformation || Geom::Transformation.new
    end
  end

  class Material
    attr_accessor :name, :display_name, :color, :alpha, :texture

    def initialize(name)
      @name = name
      @display_name = name
      @color = Color.new(200, 200, 200)
      @alpha = 1.0
      @texture = nil
    end

    def materialType
      @texture ? 1 : 0
    end
  end

  class Camera
    attr_accessor :eye, :target, :up, :fov, :perspective, :height, :aspect_ratio

    def initialize
      @eye = Geom::Point3d.new(10, -10, 10)
      @target = Geom::Point3d.new(0, 0, 0)
      @up = Geom::Vector3d.new(0, 0, 1)
      @fov = 35.0
      @perspective = true
      @height = nil
      @aspect_ratio = 0.0
    end

    def perspective?
      @perspective
    end

    def fov_is_height?
      true
    end

    def is_2d?
      false
    end
  end

  class Page
    attr_accessor :name, :description, :camera, :use_camera, :use_hidden_layers, :layers,
                  :use_hidden_objects, :use_hidden_geometry, :hidden_entities, :persistent_id,
                  :transition_time, :drawingelement_visibility

    def initialize(name)
      @name = name
      @description = ''
      @camera = Camera.new
      @use_camera = true
      @use_hidden_layers = true
      @layers = []
      @use_hidden_objects = true
      @use_hidden_geometry = false
      @hidden_entities = []
      @drawingelement_visibility = {}
      @persistent_id = "pid_#{name.downcase}"
      @transition_time = 0.0
    end

    def set_drawingelement_visibility(element, visible)
      @drawingelement_visibility[element] = visible
    end

    def get_drawingelement_visibility(element)
      @drawingelement_visibility[element]
    end

    def layer_visible?(layer)
      if @use_hidden_layers
        if @layers.include?(layer)
          false
        else
          layer.visible?
        end
      else
        layer.visible?
      end
    end

    def use_camera?
      @use_camera
    end

    def use_hidden_layers?
      @use_hidden_layers
    end

    def use_hidden_objects?
      @use_hidden_objects
    end

    def use_hidden_geometry?
      @use_hidden_geometry
    end

    def use_section_planes?
      false
    end
  end

  class Selection
    include Enumerable

    def initialize
      @items = []
    end

    def add(item)
      @items << item
    end

    def clear
      @items.clear
    end

    def empty?
      @items.empty?
    end

    def each(&block)
      @items.each(&block)
    end

    def to_a
      @items.dup
    end
  end

  class DefinitionList
    include Enumerable

    def initialize
      @items = []
    end

    def add(name)
      d = ComponentDefinition.new(name)
      @items << d
      d
    end

    def each(&block)
      @items.each(&block)
    end

    def length
      @items.length
    end
  end

  class Materials
    include Enumerable

    def initialize
      @items = []
    end

    def add(name)
      m = Material.new(name)
      @items << m
      m
    end

    def each(&block)
      @items.each(&block)
    end

    def length
      @items.length
    end
  end

  class Pages
    include Enumerable
    attr_accessor :selected_page

    def initialize
      @items = []
      @selected_page = nil
    end

    def add(name)
      p = Page.new(name)
      @items << p
      @selected_page ||= p
      p
    end

    def selected_page
      @selected_page || @items.first
    end

    def each(&block)
      @items.each(&block)
    end

    def to_a
      @items.dup
    end

    def length
      @items.length
    end
  end

  class Layers
    include Enumerable

    def initialize
      @items = [Layer.new('Layer0')]
    end

    def add(name)
      l = Layer.new(name)
      @items << l
      l
    end

    def each(&block)
      @items.each(&block)
    end

    def length
      @items.length
    end
  end

  class Model
    attr_accessor :entities, :materials, :definitions, :pages, :layers, :selection,
                  :options, :guid, :name, :description, :path, :modified

    def initialize
      @guid = 'guid_model_12345'
      @name = 'Mock Model'
      @description = 'Mock Description'
      @path = ''
      @modified = false
      @entities = Entities.new(self)
      @materials = Materials.new
      @definitions = DefinitionList.new
      @pages = Pages.new
      @layers = Layers.new
      @selection = Selection.new
      @options = {
        'UnitsOptions' => { 'LengthUnit' => 0, 'AngleUnits' => 0 }
      }
    end

    def modified?
      @modified
    end

    def georeferenced?
      false
    end

    def bounds
      bb = Geom::BoundingBox.new
      bb.add([0, 0, 0])
      bb.add([10, 10, 10])
      bb
    end

    def start_operation(name, disable_ui = false)
      true
    end

    def commit_operation
      true
    end

    def abort_operation
      true
    end

    def active_path
      nil
    end

    def active_entities
      @entities
    end

    def add_observer(obs); end
    def remove_observer(obs); end
  end

  @active_model = Model.new

  def self.active_model
    @active_model
  end

  def self.active_model=(m)
    @active_model = m
  end

  def self.version
    '23.0.0'
  end

  def self.get_locale
    'en-US'
  end

  def self.create_texture_writer
    nil
  end

  def self.read_default(section, key, default = nil)
    default
  end

  def self.write_default(section, key, value)
    value
  end

  class ModelObserver; end
  class AppObserver; end
  class SelectionObserver; end
  class EntitiesObserver; end
  class LayersObserver; end
  class PagesObserver; end
  class MaterialsObserver; end
  class DefinitionsObserver; end
  class InstanceObserver; end
  class ViewObserver; end
  class ToolsObserver; end
  class DimensionObserver; end

  def self.add_observer(obs); end
  def self.remove_observer(obs); end
end

module UI
  class Command
    attr_accessor :name, :proc, :small_icon, :large_icon, :tooltip, :status_bar_text, :menu_text

    def initialize(name, &block)
      @name = name
      @proc = block
    end
  end

  class Toolbar
    def initialize(name); end
    def add_item(cmd); end
    def show; end
    def restore; end
    def get_last_state; 1; end
  end

  class Menu
    def initialize(name = '')
      @name = name
      @items = []
    end

    def add_item(name, &block)
      @items << name
      @items.length
    end

    def add_submenu(name)
      Menu.new(name)
    end

    def add_separator; end
    def set_validation_proc(item, &block); end
  end

  @plugins_menu = Menu.new('Plugins')

  def self.menu(name)
    @plugins_menu
  end

  def self.start_timer(delay, repeat = false, &block)
    rand(1000..9999)
  end

  def self.stop_timer(timer_id); end
  def self.messagebox(msg, type = 0); 0; end
  def self.openpanel(title, dir, filter); nil; end
  def self.savepanel(title, dir, default_filename); nil; end
end

def file_loaded?(file)
  false
end

def file_loaded(file)
  true
end

MF_ENABLED = 0
MF_GRAYED = 1
MF_CHECKED = 2
MF_UNCHECKED = 3

module SibamboHistory
  module V20260826_02
  PLUGIN_VERSION = '3.3.0-rc.1' unless const_defined?(:PLUGIN_VERSION)
  PLUGIN_DISPLAY_NAME = 'BOM Engine' unless const_defined?(:PLUGIN_DISPLAY_NAME)
end

end # SibamboHistory
