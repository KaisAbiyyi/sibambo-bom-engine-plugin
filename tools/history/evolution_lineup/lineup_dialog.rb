# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'pathname'

module SibamboHistory
  module EvolutionLab
    module LineupDialog
      BATCH_SIZES = [96, 128, 256, 512, 1_024, 2_048, 4_096, 8_192].freeze
      CANONICAL_SUFFIX = '__SBE-2026.07.16-01_canonical.json.gz'.freeze

      class << self
        def default_path(slot, model)
          source = model.path.to_s
          directory = source.empty? ? File.join(Dir.home, 'Documents', 'BOMEngineExports') : File.dirname(source)
          base = source.empty? ? 'Untitled' : File.basename(source, File.extname(source))
          name = case slot.fetch('kind')
                 when 'tiered_json' then "#{base}__E1_JSON.json"
                 when 'canonical_v3' then "#{base}#{CANONICAL_SUFFIX}"
                 when 'cleanpkg' then "#{base}__E3_CleanPKG.cleanpkg"
                 else raise ArgumentError, "Unsupported historical engine: #{slot.fetch('kind')}"
                 end
          File.join(directory, name)
        end

        def validated_settings(slot, raw, target)
          raise ArgumentError, 'Pengaturan export tidak valid.' unless raw.is_a?(Hash)
          values = raw.transform_keys(&:to_sym)
          batch = Integer(values.fetch(:batch_size))
          raise ArgumentError, 'Pilih batch 96–8192 dari daftar.' unless BATCH_SIZES.include?(batch)

          path = values.fetch(:output_path).to_s.strip
          raise ArgumentError, 'Lokasi output belum diisi.' if path.empty?
          raise ArgumentError, 'Gunakan lokasi output lengkap, misalnya D:/exports/model.json.' unless Pathname.new(path).absolute?

          settings = { output_path: path, batch_size: batch, selection_only: false }
          case slot.fetch('kind')
          when 'tiered_json'
            level = values.fetch(:export_level).to_s
            raise ArgumentError, 'Tingkat JSON tidak valid.' unless %w[visual standard full].include?(level)
            raise ArgumentError, 'Output harus berakhir .json.' unless path.downcase.end_with?('.json')
            settings.merge!(export_level: level, export_textures: level == 'full' && values[:export_textures] == true,
                            include_edges: values[:include_edges] == true, pretty_print: values[:pretty_print] == true)
          when 'canonical_v3'
            actual = target::Core.canonical_output_path(path, true)
            raise ArgumentError, "Nama file yang akan dibuat: #{actual}. Pakai nama ini di kolom output." unless actual == path
            settings.merge!(export_textures: values[:export_textures] == true, pretty_print: values[:pretty_print] == true,
                            compress_output: true)
          when 'cleanpkg'
            raise ArgumentError, 'Output harus berakhir .cleanpkg.' unless path.downcase.end_with?('.cleanpkg')
            # CleanPKG's isolated adapter owns its model scope and binary format.
          else
            raise ArgumentError, 'Engine ini memakai dialog BOMC sendiri.'
          end
          settings
        end

        def show(slot:, model:, target:, &callback)
          default = default_path(slot, model)
          dialog = UI::HtmlDialog.new(
            dialog_title: "Sibambo Evolution — #{slot.fetch('title')}",
            scrollable: true, resizable: true, width: 680, height: 680,
            min_width: 440, min_height: 540, style: UI::HtmlDialog::STYLE_DIALOG
          )
          dialog.set_file(File.join(__dir__, 'lineup_dialog.html'))
          dialog.add_action_callback('onReady') do |_context|
            config = slot.slice('id', 'title', 'kind', 'sha', 'state').merge('output_path' => default)
            dialog.execute_script("setConfig(#{JSON.generate(config)})")
          end
          dialog.add_action_callback('browse') do |_context|
            selected = UI.savepanel("Save #{slot.fetch('title')}", File.dirname(default), File.basename(default))
            selected = target::Core.canonical_output_path(selected, true) if selected && slot['kind'] == 'canonical_v3'
            dialog.execute_script("setPath(#{JSON.generate(selected)})") if selected
          end
          dialog.add_action_callback('export') do |_context, json|
            begin
              raw = JSON.parse(json)
              settings = validated_settings(slot, raw, target)
              raise ArgumentError, 'Model aktif berubah; buka ulang dialog untuk model yang ingin diekspor.' unless Sketchup.active_model.equal?(model)
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
