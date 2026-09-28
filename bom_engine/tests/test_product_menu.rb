# frozen_string_literal: true

require_relative 'sketchup_mock_helper'
require_relative '../branding'
BOMEngine.send(:remove_const, :PLUGIN_DISPLAY_NAME) if BOMEngine.const_defined?(:PLUGIN_DISPLAY_NAME, false)
BOMEngine.const_set(:PLUGIN_DISPLAY_NAME, BOMEngine::Branding::EXTENSION_NAME)
require_relative '../core'

plugins_menu = UI.instance_variable_get(:@plugins_menu)
product_menu = plugins_menu.submenus.find { |menu| menu.name == 'Sibambo BOMC Engine' }
raise 'Sibambo BOMC Engine submenu was not registered.' unless product_menu

expected = [
  'Sibambo BOMC Engine: Export BOMC 1.2...',
  'Sibambo BOMC Engine: Experimental Exact size candidate (JCM)...',
  'About Sibambo BOMC Engine'
]
raise "Unexpected product menu: #{product_menu.items.inspect}" unless product_menu.items == expected

puts 'Sibambo BOMC Engine menu: standard export and explicit experimental Exact candidate PASS'
