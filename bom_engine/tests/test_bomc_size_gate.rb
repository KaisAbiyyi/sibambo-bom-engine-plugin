# Run with standalone Ruby:
#   ruby bom_engine/tests/test_bomc_size_gate.rb

require 'fileutils'
require 'tmpdir'
require_relative '../bomc_size_gate'
require_relative '../bomc_decoder'

module BOMEngine
  module Tests
    module BOMCSizeGateTest
      module_function

      def assert(condition, message)
        raise "FAIL: #{message}" unless condition
        puts "PASS: #{message}"
      end

      def run
        test_boundaries
        test_source_capture
        test_strict_exact_saved_skp_gate
        test_escalation_and_invariants
        test_escalation_reuses_preparation_and_candidates
        test_failed_candidates_are_not_published
        test_research_and_visual_never_allow_over_budget
        puts 'BOMC Size Gate Tests: ALL PASSED'
        true
      rescue StandardError => error
        warn "BOMC Size Gate Tests: FAILED\n#{error.class}: #{error.message}"
        warn Array(error.backtrace).first(8)
        false
      end

      def test_boundaries
        source = { available: true, bytes: 100 }
        # Research / Visual (90% hard limit)
        assert(BOMCSizeGate.evaluate(candidate_bytes: 90, source_info: source, profile: :research) == :pass, 'research: <=90% candidate passes')
        assert(BOMCSizeGate.evaluate(candidate_bytes: 91, source_info: source, profile: :research) == :fail, 'research: >90% candidate fails')
        assert(BOMCSizeGate.evaluate(candidate_bytes: 90, source_info: source, profile: :visual) == :pass, 'visual: <=90% candidate passes')
        assert(BOMCSizeGate.evaluate(candidate_bytes: 91, source_info: source, profile: :visual) == :fail, 'visual: >90% candidate fails')

        # Exact (no size gate)
        assert(BOMCSizeGate.evaluate(candidate_bytes: 140, source_info: source, profile: :exact) == :pass, 'exact: ignores size gate')
        assert(BOMCSizeGate.evaluate(candidate_bytes: 1, source_info: { available: false }, profile: :research) == :unavailable, 'unknown source size is explicit')
      end

      def test_source_capture
        directory = Dir.mktmpdir('bomc-source')
        begin
          path = File.join(directory, 'source.skp')
          File.open(path, 'wb') { |file| file.write('x' * 321) }
          info = BOMCSizeGate.source_info(path)
          File.open(path, 'ab') { |file| file.write('later') }
          assert(info[:available] && info[:bytes] == 321, 'source size is captured once from the saved SKP')
          assert(!BOMCSizeGate.source_info('')[:available], 'unsaved model reports unavailable source size')
        ensure
          FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
        end
      end

      def test_strict_exact_saved_skp_gate
        directory = Dir.mktmpdir('bomc-exact-strict')
        begin
          source = File.join(directory, 'native.skp')
          output = File.join(directory, 'native.bomc')
          File.binwrite(source, 'x' * 10_000)
          File.binwrite(output, 'keep-me')
          info = BOMCSizeGate.source_info(source)
          candidate = BOMCSizeGate.compile_candidate(graph_fixture, profile: :exact,
            source_info: info, strict_exact_source: true)
          assert(candidate[:status] == :pass && candidate[:candidate_bytes] < info[:bytes], 'native Exact must be strictly smaller')
          contract = BOMCDecoder.decode(candidate[:bytes])[:encoding_contract]
          assert(contract && contract[:source_skp_bytes] == info[:bytes] && contract[:target_bytes] == info[:bytes] - 1,
            'native Exact encodes the actual source and target bytes in Section 20')

          File.binwrite(source, 'x')
          info = BOMCSizeGate.source_info(source)
          begin
            BOMCSizeGate.compile_candidate(graph_fixture, profile: :exact,
              source_info: info, strict_exact_source: true)
            raise 'FAIL: equal/over-sized native Exact was accepted'
          rescue BOMCSizeGate::TargetNotMet
            assert(File.binread(output) == 'keep-me', 'over-budget native Exact preserves older output')
          end

          begin
            BOMCSizeGate.compile_candidate(graph_fixture, profile: :exact,
              source_info: { available: false }, strict_exact_source: true)
            raise 'FAIL: unsaved native Exact was accepted'
          rescue BOMCBudgetSolver::SourceSizeRequiredError
            assert(true, 'native Exact requires saved source identity')
          end

          File.binwrite(source, 'x' * 10_000)
          stale_info = BOMCSizeGate.source_info(source)
          File.binwrite(source, 'y' * 10_000)
          begin
            BOMCSizeGate.compile_candidate(graph_fixture, profile: :exact,
              source_info: stale_info, strict_exact_source: true)
            raise 'FAIL: changed native source identity was accepted'
          rescue BOMCBudgetSolver::SourceSizeRequiredError
            assert(true, 'same-size changed SKP is rejected before Exact compile')
          end
        ensure
          FileUtils.remove_entry(directory) if Dir.exist?(directory)
        end
      end

      def test_escalation_and_invariants
        graph = graph_fixture
        standard = BOMCWriter.pack(graph, profile: :production, compression_level: 6, minimal_metadata: false)
        compact = BOMCWriter.pack(graph, profile: :production, compression_level: 9, minimal_metadata: false)
        events = []
        result = BOMCSizeGate.compile(
          graph: graph,
          profile: :production,
          source_info: { available: true, bytes: compact[:bytes].bytesize },
          base_path: nil,
          checkpoint: ->(**event) { events << event }
        )
        repeated = BOMCSizeGate.compile(
          graph: graph,
          profile: :production,
          source_info: { available: true, bytes: compact[:bytes].bytesize },
          base_path: nil
        )
        assert(result[:status] == :pass && result[:strategy] == :maximum_lossless, 'bounded escalation reaches minimal lossless metadata after equality fails')
        assert(result[:candidate_bytes] < standard[:bytes].bytesize, 'selected escalated candidate is strictly smaller than source')
        assert(result[:attempts].map { |attempt| attempt[:strategy] } == [:standard, :compact, :maximum_lossless], 'strategy order is deterministic and bounded')
        assert(events.count { |event| event[:stage] == :size_gate } == 3, 'each bounded strategy reports a size-gate checkpoint')
        assert(result[:sha256] == repeated[:sha256] && result[:attempts] == repeated[:attempts], 'compression escalation choice and bytes are deterministic')

        baseline = BOMCDecoder.decode(standard[:bytes])
        selected = BOMCDecoder.decode(result[:bytes])
        assert(selected[:coverage] == baseline[:coverage] && selected[:coverage][:unaccounted] == 0, 'escalation preserves complete coverage disposition')
        assert(selected[:meshes] == baseline[:meshes], 'escalation preserves geometry, topology, precision, and UV data')
        assert(selected[:materials] == baseline[:materials] && selected[:instances] == baseline[:instances], 'escalation preserves materials, semantics, and instances')
      end

      def test_failed_candidates_are_not_published
        directory = Dir.mktmpdir('bomc-gate')
        begin
          output = File.join(directory, 'result.bomc')
          File.open(output, 'wb') { |file| file.write('keep-me') }
          error = nil
          begin
            BOMCSizeGate.compile(
              graph: graph_fixture,
              profile: :production,
              source_info: { available: true, bytes: 1 },
              base_path: nil,
              output_path: output
            )
          rescue BOMCSizeGate::TargetNotMet => caught
            error = caught
          end
          assert(!error.nil? && error.source_bytes == 1 && error.best_candidate_bytes > 1, 'unreachable target returns actionable source and best sizes')
          assert(error.delta_bytes == error.best_candidate_bytes - error.hard_budget_bytes, 'gate failure reports exact positive delta')
          assert(!error.dominant_sections.empty?, 'gate failure identifies dominant stored sections')
          assert(File.binread(output) == 'keep-me', 'failed candidates never replace an existing output')
          assert(Dir.glob(File.join(directory, '*.part')).empty?, 'failed size gate leaves no partial files')
        ensure
          FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
        end
      end

      def test_escalation_reuses_preparation_and_candidates
        graph = graph_fixture
        compact = BOMCWriter.pack(graph, profile: :production, compression_level: 9, minimal_metadata: false)
        cache = BOMCExportCache::Cache.new
        result = BOMCSizeGate.compile(
          graph: graph,
          profile: :production,
          source_info: { available: true, bytes: compact[:bytes].bytesize },
          base_path: nil,
          export_cache: cache
        )
        assert(result[:attempts].map { |attempt| attempt[:strategy] } == [:standard, :compact, :maximum_lossless], 'escalation still evaluates the frozen bounded strategy order')
        assert(cache.stats[:preparation_misses] == 2, 'normal metadata and minimal metadata each prepare exactly once')
        assert(cache.stats[:preparation_hits] == 1, 'compact compression reuses the standard raw preparation')
        assert(cache.stats[:normalization_misses] == 1 && cache.stats[:normalization_hits].zero?, 'size-gate normalizes the source once and passes the shared normalized view forward')
        assert(cache.stats[:candidate_hits].zero?, 'minimal-metadata retry consumes the first prepared candidate set directly')
      end

      def test_advisory_gate_publishes_best_complete_candidate
        directory = Dir.mktmpdir('bomc-advisory-gate')
        begin
          output = File.join(directory, 'texture-heavy.bomc')
          result = BOMCSizeGate.compile(
            graph: graph_fixture,
            profile: :production,
            source_info: { available: true, bytes: 1 },
            base_path: nil,
            output_path: output,
            enforce_smaller: false
          )
          assert(result[:status] == :over_budget, 'advisory size target reports over-budget without treating a complete BOMC as export failure')
          assert(result[:candidate_bytes] > result[:source_bytes] && result[:savings_bytes] < 0, 'over-budget result retains exact signed size diagnostics')
          assert(result[:attempts].length == BOMCSizeGate::STRATEGIES.length, 'advisory export still evaluates every bounded lossless strategy')
          assert(File.binread(output) == result[:bytes], 'advisory export atomically publishes the best complete lossless candidate')
          assert(BOMCDecoder.decode(result[:bytes]).dig(:coverage, :unaccounted).to_i.zero?, 'published over-budget candidate retains complete geometry coverage')
        ensure
          FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
        end
      end

      def test_research_and_visual_never_allow_over_budget
        directory = Dir.mktmpdir('bomc-profile-gate')
        begin
          output = File.join(directory, 'test.bomc')
          [:research, :visual].each do |prof|
            error = nil
            begin
              BOMCSizeGate.compile(
                graph: graph_fixture,
                profile: prof,
                source_info: { available: true, bytes: 1 },
                base_path: nil,
                output_path: output,
                enforce_smaller: false
              )
            rescue BOMCSizeGate::TargetNotMet => caught
              error = caught
            end
            assert(!error.nil?, "profile #{prof} never returns success with over_budget")
          end
        ensure
          FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
        end
      end

      def graph_fixture
        identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        long_name = 'source-model-name-' + ('abcdef0123456789' * 64)
        {
          source: { file_name: long_name + '.skp', model_name: long_name },
          coordinate_system: { units: 'm', handedness: 'right', up_axis: 'Z' },
          materials: [], tags: [], meshes: [], transforms: [identity],
          definitions: [{ id: 'root-definition', name: 'Root', kind: 'model_definition', mesh_id: nil, node_ids: [] }],
          nodes: [{ id: 'root-node', kind: 'root', name: 'Root', owner_definition_id: nil, definition_id: 'root-definition', transform_id: 0, visible: true }]
        }
      end
    end
  end
end

exit(BOMEngine::Tests::BOMCSizeGateTest.run ? 0 : 1)
