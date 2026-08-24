# frozen_string_literal: true

# Sketchup::Pages is enumerable and exposes #length, but does not implement
# Array's #empty? contract. This fake mirrors that API boundary.
class PagesWithoutEmpty
  include Enumerable

  def length
    0
  end

  def selected_page
    nil
  end

  def each
    return enum_for(:each) unless block_given?
  end
end

class ModelWithNoScenes
  def pages
    @pages ||= PagesWithoutEmpty.new
  end
end

root = File.expand_path('../..', __dir__)
resolver_path = File.join(
  root, 'history', 'generated', 'SBE-2026.08.19-01', 'staged',
  'bom_engine', 'scene_visibility_resolver.rb'
)
load resolver_path

profiles = SibamboHistory::V20260819_01::SceneVisibilityResolver.resolve_scenes(ModelWithNoScenes.new)
raise "expected current-view fallback, got #{profiles.inspect}" unless profiles.length == 1
raise "wrong fallback source: #{profiles.inspect}" unless profiles.first[:source] == 'current-view'

puts 'scene pages collection: PASS (Sketchup::Pages does not require #empty?)'
