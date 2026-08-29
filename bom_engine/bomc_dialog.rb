# frozen_string_literal: true

require 'json'
require_relative 'branding'

module BOMEngine
  module BOMCDialog
    module_function

    def show(default_path:, &callback)
      dialog = UI::HtmlDialog.new(
        dialog_title: "#{Branding::EXTENSION_NAME} #{Branding::EXTENSION_VERSION} — Export BOMC #{Branding::BOMC_FORMAT_VERSION}",
        scrollable: true,
        resizable: true,
        width: 520,
        height: 640,
        min_width: 420,
        min_height: 520,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dialog.set_file(File.join(__dir__, 'ui', 'bomc_export_dialog.html'))

      dialog.add_action_callback('onReady') do |_context|
        dialog.execute_script("setDefaultPath(#{JSON.generate(default_path)})")
      end

      dialog.add_action_callback('browse') do |_context|
        chosen = UI.savepanel(
          "Save #{Branding::EXTENSION_NAME} #{Branding::EXTENSION_VERSION}",
          File.dirname(default_path),
          File.basename(default_path)
        )
        dialog.execute_script("setPath(#{JSON.generate(chosen)})") if chosen
      end

      dialog.add_action_callback('export') do |_context, settings_json|
        settings = JSON.parse(settings_json, symbolize_names: true)
        dialog.close
        callback.call(settings) if callback
      rescue JSON::ParserError
        UI.messagebox('Pengaturan export BOMC tidak valid.', MB_OK)
      end

      dialog.add_action_callback('cancel') { |_context| dialog.close }
      dialog.show
      dialog
    end
  end
end
