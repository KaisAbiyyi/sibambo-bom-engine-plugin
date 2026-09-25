# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require_relative '../../tools/history/build_evolution_lab'

class TestCandidateBuildIdentity < Test::Unit::TestCase
  def test_packaged_menu_and_dialog_publish_the_same_producer_sha
    sha = '123456789abc0123456789abcdef0123456789abcd'
    record = { 'id' => 'identity-test', 'title' => 'Next Evolution (Candidate from 8082541)',
               'producerSha' => sha, 'entryKind' => 'bomc-three-profile',
               'profiles' => %w[visual research exact] }
    Dir.mktmpdir('candidate-identity') do |dir|
      staged = File.join(dir, 'staged')
      engine = File.join(staged, 'bom_engine')
      FileUtils.mkdir_p(engine)
      %w[branding.rb bomc_dialog.rb].each do |name|
        FileUtils.cp(File.join(EvolutionLabBuilder::ROOT_DIR, 'bom_engine', name), engine)
      end
      EvolutionLabBuilder.create_active_engine_entry_point(staged, record, 'identity_test', 'SibamboHistory::Identity_test')
      package = File.join(dir, 'identity.rbz')
      EvolutionLabBuilder.package_standalone_rbz(staged, package,
        { 'label' => record['title'], 'commit_sha' => sha }, 'identity_test')
      extracted = File.join(dir, 'extracted')
      FileUtils.mkdir_p(extracted)
      _out, err, status = Open3.capture3('tar', '-xf', package, '-C', extracted)
      assert status.success?, err
      script = <<~'RUBY'
        require 'json'
        $LOADED_FEATURES.concat(['sketchup.rb', 'extensions.rb'])
        def file_loaded?(*); false; end
        def file_loaded(*); end
        class SketchupExtension
          attr_accessor :description, :version, :creator, :copyright
          def initialize(*); end
        end
        module Sketchup
          def self.register_extension(*); end
        end
        module UI
          def self.menu(*); self; end
          def self.add_item(label, &block); @label = label; end
          def self.label; @label; end
          class HtmlDialog
            STYLE_DIALOG = 0
            attr_reader :scripts
            def initialize(*); @callbacks = {}; @scripts = []; end
            def set_file(*); end
            def add_action_callback(name, &block); @callbacks[name] = block; end
            def execute_script(script); @scripts << script; end
            def center; @centered = true; end
            def centered?; @centered; end
            def show; @callbacks.fetch('onReady').call(nil); end
          end
        end
        load File.join(ARGV[0], 'sibambo_bom_engine_identity_test_loader.rb')
        require File.join(ARGV[0], 'sibambo_bom_engine_identity_test', 'bom_engine', 'bomc_dialog.rb')
        dialog = BOMEngine::BOMCDialog.show(default_path: 'model.bomc')
        raise 'Dialog was not centered' unless dialog.centered?
        puts JSON.generate([UI.label, dialog.scripts.first, BOMEngine::Branding.build_sha])
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, '-e', script, extracted)
      assert status.success?, err
      assert_equal [
        'Sibambo BOM Engine — Next Evolution (Candidate from 8082541) [SHA 123456789abc]',
        'setBuildProvenance("123456789abc", "123456789abc0123456789abcdef0123456789abcd")',
        sha
      ], JSON.parse(out)
    end
  end
end
