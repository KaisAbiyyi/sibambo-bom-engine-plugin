# bom_engine/material_extractor.rb
# Extracts all materials from the model, including texture metadata.
# BOMC texture staging is evidence-gated and remains independent of geometry.

require_relative 'bomc_texture_optimizer'

module BOMEngine
  module MaterialExtractor

    # @param model       [Sketchup::Model]
    # @param tw          [Sketchup::TextureWriter]
    # @param texture_dir [String, nil] output directory; nil means skip texture export
    # @return            [Array<Hash>] material descriptors
    def self.extract(model, tw, texture_dir, checkpoint: nil, optimize_textures: false, profile: :visual, semantic_class: :class_b, material_classes: nil)
      Dir.mkdir(texture_dir) if texture_dir && !Dir.exist?(texture_dir)
      written = 0
      materials = model.materials
      total = materials.length

      materials.each_with_index.map do |mat, index|
        checkpoint.call(stage: :snapshot_materials, processed: index, total: total) if checkpoint
        c = mat.color
        entry = {
          id:            mat.object_id.to_s,
          name:          mat.name,
          display_name:  mat.display_name,
          color:         { r: c.red, g: c.green, b: c.blue, a: c.alpha,
                           hex: "#%02x%02x%02x" % [c.red, c.green, c.blue] },
          alpha:         mat.alpha,
          material_type: mat.materialType,
          attributes:    defined?(Traversal) ? Traversal.extract_dicts(mat) : {}
        }

        if mat.texture && !texture_dir.nil?
          tex       = mat.texture
          safe_name = mat.name.gsub(/[^\w\-]/, '_')
          if optimize_textures
            safe_name = "material_#{index + 1}" if safe_name.empty?
            if File.file?(File.join(texture_dir, "#{safe_name}.png")) || File.file?(File.join(texture_dir, "#{safe_name}.jpg"))
              safe_name = "#{safe_name}_#{index + 1}"
            end
          end
          tex_filename = "#{safe_name}.png"

          mat_class = if material_classes
                        material_classes[mat.name] || material_classes[mat.object_id.to_s] || semantic_class
                      else
                        semantic_class
                      end

          in_to_m = defined?(Constants::IN_TO_M) ? Constants::IN_TO_M : 0.0254

          entry[:texture] = {
            filename:          tex_filename,
            source_path:       tex.filename,
            width_m:           (tex.width  * in_to_m).round(4),
            height_m:          (tex.height * in_to_m).round(4),
            image_width_px:    tex.image_width,
            image_height_px:   tex.image_height,
            source_dimensions: { width_px: tex.image_width, height_px: tex.image_height },
            semantic_class:    mat_class
          }

          # Keep a lossless PNG fallback. An opaque JPEG candidate is accepted
          # only after its decoded pixels and byte savings pass strict gates.
          begin
            checkpoint.call(stage: :snapshot_textures, processed: index, total: total, force: true) if checkpoint
            if optimize_textures
              staged = BOMCTextureOptimizer.stage(
                texture: tex,
                directory: texture_dir,
                basename: safe_name,
                source_path: tex.filename,
                profile: profile,
                semantic_class: mat_class
              ) do |_processed_pixels, _total_pixels|
                checkpoint.call(stage: :snapshot_textures, processed: index, total: total) if checkpoint
              end
              entry[:texture][:filename] = staged[:filename]
              entry[:texture][:staging_evidence] = staged[:evidence]
              written += 1 if File.file?(staged[:path])
            else
              out_path = File.join(texture_dir, tex_filename)
              written += 1 if tex.write(out_path, true)
              entry[:texture][:staging_evidence] = { selected: :staged_png, path: out_path, staged_bytes: File.size(out_path) } if File.file?(out_path)
            end
            checkpoint.call(stage: :snapshot_textures, processed: index + 1, total: total, force: true) if checkpoint
          rescue => e
            raise if e.class.ancestors.any? { |ancestor| ancestor.respond_to?(:name) && ancestor.name.to_s.end_with?('Cancelled') }
            Logger.warn("Could not write texture for '#{mat.name}': #{e.message}") if defined?(Logger)
          end
        end

        entry
      end.tap do
        checkpoint.call(stage: :snapshot_materials, processed: total, total: total) if checkpoint
        Logger.info("Wrote #{written} texture(s) to #{texture_dir}") if texture_dir && defined?(Logger)
      end
    end

  end
end
