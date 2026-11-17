# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'fixture'
require_relative 'sketchup_mock'
require_relative '../../bomc_side'
require_relative '../../skp_side'
require_relative '../../compare'

module TestTmp
  ROOT = 'D:/projects/sibambo/scratch/r1-model-truth/test-tmp'

  def self.dir(prefix)
    FileUtils.mkdir_p(ROOT)
    Dir.mktmpdir(prefix, ROOT)
  end
end


# Runs both sides on the mock model / hand-built Hash and (optionally) the comparator.
module E2E
  CATS = %w[definitions faces edges instances images texts materials tags textures_pixels textures_colorize].freeze
  Result = Struct.new(:root, :run_dir, :skp_path, :sha, :model, :diff)

  module_function

  # `decoded_mutator` edits the BOMC-side Hash; `model_mutator` edits the mock model.
  def capture(spec: MTFixture.spec, decoded_mutator: nil, model_mutator: nil, compare: true, budget_records: 7)
    root = TestTmp.dir('e2e')
    skp_path = File.join(root, 'fixture.skp')
    File.binwrite(skp_path, 'pretend skp bytes')
    sha = Digest::SHA256.file(skp_path).hexdigest
    run_dir = File.join(root, 'model', '20261117T000000Z')
    decoded = MTFixture.decoded(spec)
    decoded_mutator&.call(decoded)
    SibamboModelTruthV1::BomcSide.run(corpus_row: MTFixture.corpus_row(sha), run_dir: run_dir, dwebp_path: 'x', ffmpeg_path: 'x', decoder: -> { decoded })
    model = SketchupMock.build(spec, skp_path)
    model_mutator&.call(model)
    Sketchup.version = '26.2.243'
    Sketchup.active_model = model
    SibamboModelTruthV1::SkpSide.quiet = true
    SibamboModelTruthV1::SkpSide.reset!
    UI.instance_variable_set(:@callback, nil)
    SibamboModelTruthV1::SkpSide.capture(run_dir: run_dir, expected_source_sha256: sha, budget_records: budget_records)
    UI.run_until
    diff = compare ? SibamboModelTruthV1::Compare.run(run_dir: run_dir) : nil
    Result.new(root, run_dir, skp_path, sha, model, diff)
  end

  def category(diff, name)
    diff[:categories].find { |c| c[:category] == name }
  end

  def verdicts(diff)
    diff[:categories].map { |c| [c[:category], c[:verdict]] }.to_h
  end
end
