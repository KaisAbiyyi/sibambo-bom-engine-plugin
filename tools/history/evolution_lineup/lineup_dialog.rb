# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'pathname'

module SibamboHistory
  module EvolutionLab
    module LineupDialog
      BATCH_SIZES = [96, 128, 256, 512, 1_024, 2_048, 4_096, 8_192].freeze
      PROFILES = %w[visual research exact].freeze

      class << self
        def default_path(slot, model, profile = 'visual')
          source = model.path.to_s
          directory = if Gem.win_platform? && Dir.exist?('D:/')
                        source.match?(/\AD:[\\\/]/i) ? File.dirname(source) : 'D:/SibamboExports'
                      else
                        source.empty? ? File.join(Dir.home, 'Documents', 'BOMEngineExports') : File.dirname(source)
                      end
          base = source.empty? ? 'Untitled' : File.basename(source, File.extname(source))
          extension = case slot.fetch('engine')
                      when 'e1' then '.json'
                      when 'e2' then '.json.gz'
                      when 'e3' then '.cleanpkg'
                      else raise ArgumentError, "Unsupported Evolution writer: #{slot.fetch('engine')}"
                      end
          File.join(directory, "#{base}__#{slot.fetch('engine').upcase}__#{profile.upcase}#{extension}")
        end

        def validated_settings(slot, raw, target)
          raise ArgumentError, 'Pengaturan export tidak valid.' unless raw.is_a?(Hash)
          values = raw.transform_keys(&:to_sym)
          batch = Integer(values.fetch(:batch_size))
          raise ArgumentError, 'Pilih batch 96–8192 dari daftar.' unless BATCH_SIZES.include?(batch)
          profile = values.fetch(:profile).to_s.downcase
          raise ArgumentError, 'Profil harus Visual, Research, atau Exact.' unless PROFILES.include?(profile) && slot.fetch('profiles').include?(profile)
          path = values.fetch(:output_path).to_s.strip
          raise ArgumentError, 'Lokasi output belum diisi.' if path.empty?
          raise ArgumentError, 'Gunakan lokasi output lengkap.' unless Pathname.new(path).absolute?
          if Gem.win_platform? && Dir.exist?('D:/') && !File.expand_path(path).match?(/\AD:[\\\/]/i)
            raise ArgumentError, 'Pilih lokasi ekspor di drive D:.'
          end
          actual = target.normalize_output_path(path, profile)
          raise ArgumentError, "Nama output untuk profil ini harus: #{actual}" unless actual == path
          { output_path: path, batch_size: batch, profile: profile.to_sym }
        end

        def show(slot:, model:, target:, &callback)
          default = default_path(slot, model)
          dialog = UI::HtmlDialog.new(
            dialog_title: "Sibambo Evolution — #{slot.fetch('title')}",
            scrollable: true, resizable: true, width: 680, height: 610,
            min_width: 440, min_height: 520, style: UI::HtmlDialog::STYLE_DIALOG
          )
          dialog.set_file(File.join(__dir__, 'lineup_dialog.html'))
          dialog.add_action_callback('onReady') do |_context|
            config = slot.slice('id', 'engine', 'title', 'kind', 'formatVersion', 'sha', 'state', 'profiles').merge('output_path' => default)
            dialog.execute_script("setConfig(#{JSON.generate(config)})")
          end
          dialog.add_action_callback('browse') do |_context, profile|
            selected = UI.savepanel("Save #{slot.fetch('title')}", File.dirname(default), File.basename(default_path(slot, model, profile.to_s)))
            selected = target.normalize_output_path(selected, profile) if selected
            dialog.execute_script("setPath(#{JSON.generate(selected)})") if selected
          end
          dialog.add_action_callback('export') do |_context, json|
            begin
              settings = validated_settings(slot, JSON.parse(json), target)
              raise ArgumentError, 'Model aktif berubah; buka ulang dialog.' unless Sketchup.active_model.equal?(model)
              FileUtils.mkdir_p(File.dirname(settings.fetch(:output_path)))
              dialog.close
              callback.call(settings)
            rescue StandardError => error
              UI.messagebox(error.message, MB_OK)
            end
          end
          dialog.add_action_callback('cancel') { |_context| dialog.close }
          dialog.center
          dialog.show
          @dialogs ||= {}
          @dialogs[slot.fetch('id')] = dialog
          dialog
        end
      end
    end
  end
end
