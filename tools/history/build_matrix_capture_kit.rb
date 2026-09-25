# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'time'
require_relative 'build_evolution_lab'

module MatrixCaptureKitBuilder
  CORE_SHA='97ce81b62d3a6953675d52b836b4ead0bde6acfdd58c75897a05d878a7faaaee'.freeze
  VERIFIER_SHA='86f093bb7a89d44c87f74df4d5543380750c909cec55e858c44b0ffcd825e145'.freeze
  PACKAGE_SHA='530aedc1a1a4c596c3446e0c565e3f04f659eb8935df9629a9fa9ac0fff99e74'.freeze
  CATEGORIES=%w[tiny small-textured medium-architectural complex-architectural texture-heavy scene-heavy].freeze
  def self.build(source_kit:, corpus_path:, assets_root:, consumer_root:, output:)
    output=File.expand_path(output)
    raise 'Destination exists; preserve it and choose a new kit directory.' if File.exist?(output)
    source_kit=File.realpath(source_kit)
    {'capture_e4.rb'=>CORE_SHA,'verify_capture.rb'=>VERIFIER_SHA,'sibambo_bom_engine_next_from_8082541.rbz'=>PACKAGE_SHA}.each do |name,sha|
      raise "Historical kit #{name} hash mismatch" unless Digest::SHA256.file(File.join(source_kit,name)).hexdigest==sha
    end
    manifest=JSON.parse(File.read(File.join(source_kit,'manifest.json')))
    raise 'Historical package identity mismatch' unless manifest['package_sha256']==PACKAGE_SHA
    head,err,ok=Open3.capture3('git','rev-parse','HEAD',chdir:consumer_root)
    raise "Consumer Git unavailable: #{err}" unless ok.success? && head.strip.match?(/\A[0-9a-f]{40}\z/)
    status,err,ok=Open3.capture3('git','status','--porcelain',chdir:consumer_root)
    raise "Consumer status unavailable: #{err}" unless ok.success?
    corpus=JSON.parse(File.read(corpus_path))
    jobs=CATEGORIES.each_with_index.map do |category,i|
      matches=corpus.fetch('items').select { |item| item['category']==category }
      raise "Missing/ambiguous category #{category}" unless matches.length==1
      item=matches.first; path=File.realpath(File.join(assets_root,item.fetch('skp_path')))
      sha=Digest::SHA256.file(path).hexdigest
      raise "SKP hash mismatch for #{category}" unless sha==item.fetch('skp_sha256')
      {'id'=>"#{i+1}-#{category}",'category'=>category,'fixture_id'=>"runtime-#{item.fetch('id')}",
       'source'=>{'path'=>path.tr('\\','/'),'sha256'=>sha,'bytes'=>File.size(path)},
       'namespace'=>"SibamboMatrixCore#{i+1}",'verifier_namespace'=>"SibamboMatrixVerifier#{i+1}"}
    end
    Dir.mkdir(output)
    FileUtils.mkdir_p(File.join(output,'support'))
    %w[runner.rb native_reference.rb].each { |name| FileUtils.cp(File.join(__dir__,'matrix_capture',name),File.join(output,'support',name)) }
    binding={'target_sha'=>head.strip,'repository'=>File.expand_path(consumer_root).tr('\\','/'),'dirty_at_preparation'=>!status.empty?,
      'meaning'=>'planned consumer target, not proof of browser execution; clean audit/binding required later'}
    jobs.each do |job|
      dir=File.join(output,job['id']); Dir.mkdir(dir); Dir.mkdir(File.join(dir,'results'))
      updated=manifest.merge('consumer_sha'=>head.strip,'created_at'=>Time.now.utc.iso8601,
        'capture_task_source'=>job['source'],'historical_manifest_sha256'=>Digest::SHA256.file(File.join(source_kit,'manifest.json')).hexdigest,
        'consumer_binding'=>binding,'state'=>'development','ready'=>false)
      File.write(File.join(dir,'manifest.json'),JSON.pretty_generate(updated))
      core=File.read(File.join(source_kit,'capture_e4.rb')).gsub('SibamboCaptureKit',job['namespace'])
      # All calls go through the new guarded cooperative runner, not the old RUMAH-L-only entry point.
      core << "\nmodule #{job['namespace']}\n def self.start_interactive; raise 'Use the Matrix Capture menu.'; end\nend\n"
      File.write(File.join(dir,'capture_core.rb'),core)
      verifier=File.read(File.join(source_kit,'verify_capture.rb')).gsub('T8CaptureVerifier',job['verifier_namespace'])
      File.write(File.join(dir,'verify_capture.rb'),verifier)
      FileUtils.cp(File.join(source_kit,'sibambo_bom_engine_next_from_8082541.rbz'),dir)
      job['files']=%w[manifest.json capture_core.rb verify_capture.rb].map { |name| [name,Digest::SHA256.file(File.join(dir,name)).hexdigest] }.to_h
    end
    index={'schema_version'=>'t7-matrix-capture-kit-v1','ready'=>false,'status'=>'prepared_for_tiny_operator_smoke',
      'producer_sha'=>manifest['producer_sha'],'package_sha256'=>PACKAGE_SHA,'consumer_binding'=>binding,'jobs'=>jobs,
      'preserved_rumah_l'=>File.join(source_kit,'results').tr('\\','/'),'deferred'=>['native-reference mapping/fidelity comparison','full certification','matching E3 capture']}
    File.write(File.join(output,'kit-index.json'),JSON.pretty_generate(index))
    launcher="require #{File.join(output,'support/runner.rb').tr('\\','/').dump}\nSibamboMatrixCapture.install_menu(#{output.tr('\\','/').dump}) if defined?(Sketchup) && defined?(UI)\n"
    File.write(File.join(output,'sibambo_matrix_capture_launcher.rb'),launcher)
    launcher_dir=File.join(output,'launcher-package'); Dir.mkdir(launcher_dir)
    File.write(File.join(launcher_dir,'sibambo_matrix_capture_launcher.rb'),launcher)
    # A new, isolated output only. This package installs the menu, not the engine.
    EvolutionLabBuilder.zip_folder(launcher_dir,File.join(output,'sibambo_matrix_capture_menu.rbz'))
    File.write(File.join(output,'OPERATOR_GUIDE.md'),"# Matrix capture — mulai kecil dulu\n\nKit belum dipasang dan belum diuji di SketchUp nyata. Engine E4 tidak diganti.\n\n1. Setelah Codex memasang menu, buka `#{jobs.first['source']['path']}`. Jangan edit atau save ulang sumber.\n2. Klik Extensions > Sibambo E4 — Matrix Capture [bd67826] > 1. test.skp — 3 profiles.\n3. Tunggu selesai, jangan ganti model. Kirim status ke Codex; jangan lanjut model lain sebelum hasil tiny diperiksa.\n\nSetiap percobaan punya folder baru. Capture RUMAH L lama tidak disentuh. Hasil tetap pending certification. Native reference merupakan data API mentah, bukan laporan fidelity yang sudah lulus.\n")
    index
  end
end

if $PROGRAM_NAME==__FILE__
  raise 'Usage: ruby build_matrix_capture_kit.rb SOURCE_KIT CORPUS ASSETS_ROOT CONSUMER_ROOT NEW_OUTPUT' unless ARGV.length==5
  result=MatrixCaptureKitBuilder.build(source_kit:ARGV[0],corpus_path:ARGV[1],assets_root:ARGV[2],consumer_root:ARGV[3],output:ARGV[4])
  puts JSON.pretty_generate(result)
end
