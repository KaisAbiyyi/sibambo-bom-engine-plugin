# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'
require 'time'
require_relative 'native_reference'

module SibamboMatrixCapture
  def self.validate_model!(model, source)
    raise 'Open the selected saved SKP first.' unless model && File.file?(model.path.to_s)
    raise 'Model has unsaved changes. Stop and ask Codex before saving/re-pinning the source.' if model.modified?
    actual = File.realpath(model.path).tr('\\','/')
    expected = File.realpath(source.fetch('path')).tr('\\','/')
    raise "Wrong model. Open #{source['path']}" unless actual.casecmp?(expected)
    raise 'Source file changed since kit preparation. Ask Codex to inspect it; do not overwrite the pin.' unless Digest::SHA256.file(actual).hexdigest == source.fetch('sha256')
    true
  end

  def self.reserve_session(root)
    FileUtils.mkdir_p(root)
    dir = File.join(root, "capture-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}")
    Dir.mkdir(dir) # Exclusive reservation, never delete/reuse an older session.
    dir
  end

  def self.start(root, id)
    index = JSON.parse(File.read(File.join(root,'kit-index.json')))
    item = index.fetch('jobs').find { |job| job['id']==id }
    raise 'Unknown capture task' unless item
    model=Sketchup.active_model
    validate_model!(model,item.fetch('source'))
    job_dir=File.join(root,id)
    %w[capture_core.rb verify_capture.rb manifest.json].each do |name|
      raise "Kit file changed: #{name}" unless Digest::SHA256.file(File.join(job_dir,name)).hexdigest==item.fetch('files').fetch(name)
    end
    require File.join(job_dir,'capture_core.rb')
    require File.join(job_dir,'verify_capture.rb')
    core=Object.const_get(item.fetch('namespace')); verifier=Object.const_get(item.fetch('verifier_namespace'))
    engine=core.ensure_extension_loaded!
    job_class=engine.const_get(:ConversionJob)
    raise 'Another export is running.' if job_class.active&.running?
    result_dir=reserve_session(File.join(job_dir,'results'))
    status_path=File.join(result_dir,'session-status.json')
    job=job_class.start(title:"E4 capture — #{File.basename(model.path)}",output_path:result_dir,batch_size:256) do |progress|
      begin
        checkpoint=->(event) do
          raise 'Active model changed during capture.' unless Sketchup.active_model.equal?(model) && !model.modified?
          progress.call(event)
        end
        reference=SibamboNativeReference.capture(model,File.join(result_dir,'native-reference.jsonl'),source:item.fetch('source'),
          sketchup_version:Sketchup.version,checkpoint:checkpoint)
        records={}
        core::PROFILES.each do |profile|
          validate_model!(Sketchup.active_model,item.fetch('source'))
          records[profile]=core.export_profile(profile,output_dir:result_dir,checkpoint:checkpoint)
          raise "#{profile} export failed; earlier outputs are preserved." unless records[profile]['export_status']=='success'
        end
        validate_model!(Sketchup.active_model,item.fetch('source'))
        verification=verifier.verify(result_dir,skip_consumer_inspection:true)
        raise 'Post-capture verification incomplete; outputs preserved.' unless verification.fetch(:verified_captures,{}).length==3 && verification[:status]=='captured_pending_certification'
        File.write(status_path,JSON.pretty_generate({status:'captured_pending_certification',ready:false,source:item['source'],
          reference:reference,profiles:records,verification:verification,consumer_binding:index['consumer_binding']}))
        {path:result_dir,bytes:records.values.sum { |r| r['bomc_bytes'] },profile:'visual+research+exact',status:'captured_pending_certification'}
      rescue StandardError => error
        File.write(status_path,JSON.pretty_generate({status:'failed_or_cancelled',ready:false,error:"#{error.class}: #{error.message}"}))
        raise
      end
    end
    timer=nil
    timer=UI.start_timer(0.5,true) do
      next if job.running?
      UI.stop_timer(timer)
      state=File.file?(status_path) ? JSON.parse(File.read(status_path)) : {'status'=>'incomplete'}
      UI.messagebox("#{File.basename(model.path)}: #{state['status']}.\nHasil: #{result_dir}\nKirim status ke Codex. Jangan jalankan model berikutnya dulu. Release belum ready.")
    end
    job
  end
  def self.install_menu(root)
    return if @menu_installed
    index=JSON.parse(File.read(File.join(root,'kit-index.json')))
    menu=UI.menu('Extensions').add_submenu('Sibambo E4 — Matrix Capture [bd67826]')
    index.fetch('jobs').each_with_index do |item,i|
      menu.add_item("#{i+1}. #{File.basename(item['source']['path'])} — 3 profiles") do
        begin; start(root,item['id']); rescue StandardError => e; UI.messagebox("Capture tidak dimulai: #{e.message}"); end
      end
    end
    @menu_installed=true
  end
end
