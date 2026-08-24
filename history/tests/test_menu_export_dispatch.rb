# frozen_string_literal: true

require_relative '../batch_runner'

root = File.expand_path('../..', __dir__)
menu_path = File.join(root, 'dist', 'history', 'staging', 'evolution_lab', 'master_menu.rb')
raise "master menu missing: #{menu_path}" unless File.file?(menu_path)

menu = File.read(menu_path, encoding: 'UTF-8')
(1..9).each do |number|
  id = format('%02d', number)
  dispatch = "BatchRunner.start_for_format(#{id.inspect})"
  raise "menu [#{id}] does not dispatch an export" unless menu.include?(dispatch)
end
raise 'all-format batch command missing' unless menu.include?('BatchRunner.start_or_resume')

runner = SibamboHistory::EvolutionLab::BatchRunner
(1..9).each do |number|
  id = format('%02d', number)
  path = runner.send(:output_path_for, 'C:/exports/RUMAH L', 'RUMAH L', id)
  basename = File.basename(path)
  raise "[#{id}] missing deterministic prefix: #{basename}" unless basename.start_with?("[#{id}] RUMAH L__SBE-")
  raise "[#{id}] escaped requested folder" unless File.dirname(path).tr('\\', '/') == 'C:/exports/RUMAH L'
end

puts 'menu export dispatch: PASS ([01]-[09], deterministic folders/prefixes)'
