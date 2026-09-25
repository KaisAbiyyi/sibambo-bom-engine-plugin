# frozen_string_literal: true
require_relative 'build_adaptive_preview_kit'

# Texture-only experiment; no extension registration, install, or release change.
module ExactColorMapPreviewBuilder
  def self.build(output:, root: AdaptivePreviewKit::ROOT)
    output=File.expand_path(output).tr('\\','/')
    root=File.expand_path(root).tr('\\','/')
    raise ArgumentError,'Output already exists; use a new capture kit directory' if File.exist?(output)
    files=AdaptivePreviewKit.runtime_files(root)
    source_sha=AdaptivePreviewKit.inventory_digest(files)
    template=File.join(__dir__,'exact_color_map_capture.rb')
    pixels_template=File.join(__dir__,'exact_color_map_pixels.rb')
    tooling_sha=Digest::SHA256.hexdigest(File.binread(__FILE__)+File.binread(template)+File.binread(pixels_template)+File.binread(File.join(__dir__,'build_adaptive_preview_kit.rb')))
    namespace="ExactJcm_#{Digest::SHA256.hexdigest(source_sha+tooling_sha)[0,16]}"
    FileUtils.mkdir_p(output)
    files.each do |relative,sha|
      bytes=File.binread(File.join(root,relative))
      raise 'Source changed while snapshotting' unless Digest::SHA256.hexdigest(bytes)==sha
      destination=File.join(output,relative)
      FileUtils.mkdir_p(File.dirname(destination))
      bytes=AdaptivePreviewKit.transform(bytes.force_encoding('UTF-8'),namespace) if relative.end_with?('.rb')
      File.binwrite(destination,bytes)
    end
    FileUtils.cp(template,File.join(output,'capture.rb'))
    FileUtils.cp(pixels_template,File.join(output,'pixels.rb'))
    File.write(File.join(output,'run_pixels.rb'),<<~RUBY)
      require_relative 'bom_engine/bomc_jpeg_color_map'
      require_relative 'pixels'
      ExactColorMapPixels.configure(__dir__, SibamboHistory::#{namespace})
    RUBY
    File.write(File.join(output,'run.rb'),<<~RUBY)
      require_relative 'bom_engine/bomc_texture_optimizer'
      require_relative 'capture'
      ExactColorMapPreview.configure(__dir__, SibamboHistory::#{namespace})
    RUBY
    File.write(File.join(output,'OPERATOR_GUIDE.md'),<<~TEXT)
      # Host-pixel capture only — release not ready

      Source tree: #{source_sha}
      Tooling: #{tooling_sha}

      Open the saved model in SketchUp 2026 without unsaved changes. Do not run an export.
      In Extensions > Developer > Ruby Console, run this once:

      ```ruby
      load "#{output}/run_pixels.rb"; ExactColorMapPixels.start
      ```

      This captures up to four large JPEG textures, not geometry. It extracts native JPEGs
      and original host pixel buffers, without PNG encoding or WebP compression. No reinstall.
      Native image extraction/decoding may still pause the UI briefly. Between phases and
      raw-data blocks, the capture returns control to SketchUp. Do not edit/switch the model.
      To cancel between phases, enter `ExactColorMapPixels.cancel` in Ruby Console.

      Wait for `captured_pending_offline_verification`, then send the result to Codex.
      Do not rerun `run.rb` / `ExactColorMapPreview.start`; that is the old heavy comparison.
      Each run creates a separate results/pixels-* directory. Old captures remain untouched.
      Raw files may use about 0.5 GB for four 16-megapixel textures. They are evidence files,
      not the proposed final model size. No ready/certification status is granted by capture.
    TEXT
    inventory=Dir.glob(File.join(output,'**','*')).select { |p| File.file?(p) }.sort.map do |path|
      [path.delete_prefix(output+'/'),Digest::SHA256.file(path).hexdigest]
    end.to_h
    manifest={'schema'=>'exact-color-map-preview-v1','ready'=>false,'status'=>'prepared_pending_runtime',
      'source_tree_sha256'=>source_sha,'tooling_sha256'=>tooling_sha,'namespace'=>namespace,
      'required_loader'=>'bomc-next-jcm-v1','files'=>inventory,'source_files'=>files,
      'scope'=>'Texture-only candidate comparison. No geometry, installation or certification.'}
    File.write(File.join(output,'manifest.json'),JSON.pretty_generate(manifest))
    manifest
  end
end
if __FILE__==$PROGRAM_NAME
  options={}
  OptionParser.new { |p| p.on('--output PATH') { |v| options[:output]=v } }.parse!
  puts JSON.pretty_generate(ExactColorMapPreviewBuilder.build(**options).reject { |k,_| %w[files source_files].include?(k) })
end
