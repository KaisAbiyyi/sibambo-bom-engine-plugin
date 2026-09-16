# frozen_string_literal: true

require 'test/unit'
require 'json'
require 'tmpdir'
require_relative '../bomc_extension'

class TestBOMCCanonicalPublication < Test::Unit::TestCase
  def setup
    # This fixture uses the same 'root' definition kind as CanonicalGraphBuilder,
    # unlike the already-normalized model-eval fixtures used by older tests.
    @graph = JSON.parse(File.read(File.expand_path('../../examples/canonical-v3-small.json', __dir__)), symbolize_names: true)
  end

  [:visual, :research, :exact].each do |profile|
    define_method("test_canonical_root_publishes_with_#{profile}_validation") do
      Dir.mktmpdir('bomc-canonical-publication') do |dir|
        path = File.join(dir, 'model.bomc')
        context = BOMEngine::BOMCExtension.send(:export_context, path, ->(*) {}, profile: profile)
        begin
          candidate = context[:compile].call(@graph, { available: true, bytes: 1_000_000 }, path, ->(**_) {})
          validation = context[:validate].call(candidate, @graph)
          assert_equal true, validation[:report][:passed]
          context[:publish].call(candidate, validation, path)
          decoded = BOMEngine::BOMCDecoder.decode(File.binread(path))
          assert_equal 'model_definition', decoded[:definitions][0][:kind]
          assert_equal 'root', decoded[:instances][0][:kind], 'Root instance is a different enum and must stay root'
          assert_equal 0, decoded[:definitions][0][:mesh]
          assert_equal 'Model Root', decoded[:definitions][0][:name]
          assert_equal 'root', @graph[:definitions][0][:kind], 'Do not mutate the canonical graph contract'
        ensure
          context[:cleanup].call
        end
      end
    end
  end

  def test_definition_corruption_is_still_rejected
    candidate = BOMEngine::BOMCSizeGate.compile_candidate(@graph, profile: :exact)
    decoded = BOMEngine::BOMCDecoder.decode(candidate.fetch(:bytes))
    { name: 'Wrong name', kind: 'group_definition', mesh: nil }.each do |field, corrupt_value|
      corrupted = Marshal.load(Marshal.dump(decoded))
      corrupted[:definitions][0][field] = corrupt_value
      error = assert_raise(BOMEngine::BOMCValidator::ProfileValidationError) do
        BOMEngine::BOMCValidator.validate_profile!(source: @graph, decoded: corrupted, profile: :exact)
      end
      assert_include error.report[:failures], 'definitions'
    end
  end
end
