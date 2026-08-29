# frozen_string_literal: true

require 'test/unit'
require_relative '../branding'

class TestBOMEngineBranding < Test::Unit::TestCase
  def test_public_extension_identity
    assert_equal 'Sibambo BOMC Engine', BOMEngine::Branding::EXTENSION_NAME
    assert_equal '1.2.0', BOMEngine::Branding::EXTENSION_VERSION
    assert_equal '1.2', BOMEngine::Branding::BOMC_FORMAT_VERSION
  end

  def test_about_text_exposes_extension_format_and_build_versions
    text = BOMEngine::Branding.about_text(build_sha: 'eca60c82b67c2aa12e47555d21be0b3eb98b562f')

    assert_include text, 'Sibambo BOMC Engine'
    assert_include text, 'Extension version: 1.2.0'
    assert_include text, 'BOMC format: 1.2'
    assert_include text, 'Build: eca60c82b67c'
  end

  def test_public_ui_uses_only_new_product_name
    root = File.expand_path('../..', __dir__)
    public_files = [
      File.join(root, 'bom_engine_loader.rb'),
      File.join(root, 'bom_engine', 'core.rb'),
      File.join(root, 'bom_engine', 'ui_dialog.rb'),
      File.join(root, 'bom_engine', 'ui', 'export_dialog.html'),
      File.join(root, 'bom_engine', 'bomc_extension.rb')
    ]
    public_text = public_files.map { |path| File.read(path, encoding: 'UTF-8') }.join("\n")

    assert_include public_text, 'Sibambo BOMC Engine'
    assert_not_match(/BOM Engine Semantic Exporter|BOM Engine —|BOM Engine Export/, public_text)
  end
end
