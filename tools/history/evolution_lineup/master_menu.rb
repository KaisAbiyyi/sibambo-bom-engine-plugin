# frozen_string_literal: true

require 'json'
require_relative 'lineup_dialog'

module SibamboHistory
  module EvolutionLab
    MENU_TITLE = 'Sibambo BOM Engine Evolution'
    ENGINES = JSON.parse(File.read(File.join(__dir__, 'engines.json'))).select { |slot| %w[e2 e3 e4].include?(slot.fetch('engine')) }.freeze

    class << self
      def open_overnight_batch(engine = 'e4')
        raise ArgumentError, 'Unsupported batch version.' unless %w[e2 e3 e4].include?(engine)
        slot = ENGINES.find { |item| item.fetch('id') == 'e4-bomc' && item.fetch('engine') == 'e4' }
        raise 'Evolution E4 slot is unavailable.' unless slot
        entry = File.join(__dir__, slot.fetch('entry'))
        raise 'Evolution E4 runtime entry is missing.' unless File.file?(entry)
        require entry
        target = slot.fetch('moduleName').split('::').inject(Object) { |scope, name| scope.const_get(name) }
        target.load_engine::OvernightBatch::Dialog.show(engine: engine)
      rescue StandardError => error
        UI.messagebox("Overnight Batch failed:\n#{error.message}", MB_OK)
      end

      def open_engine(id, model = Sketchup.active_model)
        raise ArgumentError, 'Tidak ada model SketchUp yang terbuka.' unless model
        slot = ENGINES.find { |item| item.fetch('id') == id }
        raise ArgumentError, 'Pilihan engine tidak tersedia.' unless slot
        entry = File.join(__dir__, slot.fetch('entry'))
        raise "File engine tidak ditemukan: #{entry}" unless File.file?(entry)
        require entry
        target = slot.fetch('moduleName').split('::').inject(Object) { |scope, name| scope.const_get(name) }
        runtime = target.load_engine
        if slot.fetch('kind') == 'bomc_three_profile'
          runtime::BOMCExtension.export_interactive
        else
          LineupDialog.show(slot: slot, model: model, target: target) do |settings|
            target.export_current_model(model, settings)
          end
        end
      rescue StandardError => error
        UI.messagebox("Evolution export gagal:\n#{error.message}", MB_OK)
      end

      def init_menus
        return if @menus_initialized
        @menus_initialized = true
        active_menu = UI.menu('Extensions').add_submenu(MENU_TITLE)
        %w[e2 e3 e4].each do |engine|
          active_menu.add_item("Batch #{engine.upcase} Export...") { open_overnight_batch(engine) }
        end
        ENGINES.each do |slot|
          label = "#{slot.fetch('title')} · #{slot.fetch('sha')[0, 8]}"
          active_menu.add_item(label) { open_engine(slot.fetch('id'), Sketchup.active_model) }
        end
        active_menu.add_separator
        active_menu.add_item('Tentang Evolution') do
          UI.messagebox('Tiga format Evolution memakai capture runtime kandidat yang sama. E2–E3 menyimpan commit historis hanya sebagai baseline identitas. Belum tersertifikasi lintas model.', MB_OK)
        end
      end
    end
  end
end

SibamboHistory::EvolutionLab.init_menus
