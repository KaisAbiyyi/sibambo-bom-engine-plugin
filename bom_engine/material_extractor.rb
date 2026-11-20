# bom_engine/material_extractor.rb
# Extracts all materials from the model, including texture metadata.
# BOMC texture staging is evidence-gated and remains independent of geometry.

require 'digest'
require 'zlib'
require_relative 'bomc_texture_optimizer'
require_relative 'performance_trace'

module BOMEngine
  module MaterialExtractor

    # @param model       [Sketchup::Model]
    # @param tw          [Sketchup::TextureWriter]
    # @param texture_dir [String, nil] output directory; nil means skip texture export
    # @return            [Array<Hash>] material descriptors
    def self.write_pixel_fallback_png(rep, path)
      width = Integer(rep.width)
      height = Integer(rep.height)
      bits = Integer(rep.bits_per_pixel)
      padding = Integer(rep.row_padding)
      raise ArgumentError, 'Invalid embedded pixel dimensions' if width <= 0 || height <= 0 || padding < 0
      raise ArgumentError, "Unsupported embedded pixel format #{bits}" unless [24, 32].include?(bits)

      channels = bits / 8
      row_bytes = width * channels
      stride = row_bytes + padding
      data = rep.data
      unless data.is_a?(String) && data.bytesize == stride * height
        raise ArgumentError, 'Embedded texture pixel buffer is unavailable or incomplete'
      end
      windows_bgr = Gem.win_platform?
      chunk = lambda do |io, type, bytes|
        io.write([bytes.bytesize].pack('N'))
        io.write(type)
        io.write(bytes)
        io.write([Zlib.crc32(type + bytes)].pack('N'))
      end
      File.open(path, 'wb') do |io|
        io.write("\x89PNG\r\n\x1a\n".b)
        chunk.call(io, 'IHDR'.b, [width, height, 8, channels == 4 ? 6 : 2, 0, 0, 0].pack('NNCCCCC'))
        compressor = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION)
        begin
          height.times do |row_index|
            row = data.byteslice(row_index * stride, row_bytes)
            if windows_bgr
              offset = 0
              while offset < row_bytes
                blue = row.getbyte(offset)
                row.setbyte(offset, row.getbyte(offset + 2))
                row.setbyte(offset + 2, blue)
                offset += channels
              end
            end
            encoded = compressor.deflate("\x00".b + row)
            chunk.call(io, 'IDAT'.b, encoded) unless encoded.empty?
          end
          final = compressor.finish
          chunk.call(io, 'IDAT'.b, final) unless final.empty?
        ensure
          compressor.close
        end
        chunk.call(io, 'IEND'.b, ''.b)
      end
      raise 'Lossless pixel fallback PNG was not written' unless File.file?(path) && File.size(path).positive?
      path
    rescue StandardError
      File.delete(path) if File.file?(path)
      raise
    end

    def self.extract(model, tw, texture_dir, checkpoint: nil, optimize_textures: false, profile: :visual, semantic_class: :class_b, material_classes: nil, allow_jpeg_color_map: false, allow_semantic_colorize: true, record_reference_pixel_hash: false, prepared_color_maps: nil, candidate_cache: nil, cooperative_png: false, material_sources: nil)
      Dir.mkdir(texture_dir) if texture_dir && !Dir.exist?(texture_dir)
      written = 0
      materials = material_sources || model.materials.to_a
      total = materials.length
      PerformanceTrace.increment(:materials_seen, total)
      color_map_budget = allow_jpeg_color_map ? { remaining_pixels: 128_000_000, hashes: {} } : nil

      work = materials.each_with_index.to_a
      if allow_jpeg_color_map && profile.to_s.downcase.to_sym == :exact
        # JCM is globally pixel-budgeted. Process the largest JPEG-backed
        # textures first so material insertion order cannot consume the budget
        # before the dominant assets are measured.
        work.sort_by! do |mat, index|
          texture = mat.texture
          jpeg = texture && %w[.jpg .jpeg].include?(File.extname(texture.filename.to_s).downcase)
          pixels = texture ? texture.image_width.to_i * texture.image_height.to_i : 0
          [jpeg ? 0 : 1, -pixels, index]
        end
      end

      results = Array.new(total)
      work.each do |mat, index|
        checkpoint.call(stage: :snapshot_materials, processed: index, total: total, operation_label: mat.name, unit: 'material') if checkpoint
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
        if mat.materialType.to_i == 2 && mat.respond_to?(:colorize_deltas) && mat.respond_to?(:colorize_type)
          raw_mode=mat.colorize_type
          shift_constant=defined?(Sketchup::Material::COLORIZE_SHIFT) ? Sketchup::Material::COLORIZE_SHIFT : 0
          h,l,saturation=Array(mat.colorize_deltas).map(&:to_f)
          entry[:colorize_type]=raw_mode==shift_constant ? 'shift' : 'tint'
          entry[:colorize_deltas]={h:h,l:l,s:saturation}
        end

        if mat.texture && !texture_dir.nil?
          tex       = mat.texture
          # Native SketchUp serializers and embedded Ruby can reject paths over
          # MAX_PATH even when portable Ruby accepts them. Keep export-local
          # asset names short, unique across every PNG/fallback/codec variant,
          # and independent of user material names. Display/source names above
          # remain intact; historical non-optimized exports keep their naming.
          safe_name = optimize_textures ? "m#{index + 1}" : mat.name.gsub(/[^\w\-]/, '_')
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
            checkpoint.call(stage: :snapshot_textures, processed: index, total: total, operation_label: mat.name, unit: 'material', force: true) if checkpoint
            if optimize_textures
              staged = BOMCTextureOptimizer.stage(
                texture: tex,
                directory: texture_dir,
                basename: safe_name,
                source_path: tex.filename,
                profile: profile,
                semantic_class: mat_class,
                allow_jpeg_color_map: allow_jpeg_color_map,
                allow_semantic_colorize: allow_semantic_colorize,
                record_reference_pixel_hash: record_reference_pixel_hash,
                color_map_budget: color_map_budget,
                prepared_color_maps: prepared_color_maps,
                candidate_cache: candidate_cache,
                cooperative_png: cooperative_png,
                appearance: {material_type: entry[:material_type], colorize_type: entry[:colorize_type],
                  colorize_deltas: entry[:colorize_deltas]}
              ) do |_processed_pixels, _total_pixels, phase|
                checkpoint.call(stage: :snapshot_textures, processed: index, total: total, operation_label: phase ? "#{mat.name} / #{phase}" : mat.name, unit: 'material') if checkpoint
              end
              entry[:texture][:filename] = staged[:filename]
              entry[:texture][:staging_evidence] = staged[:evidence]
              selected_bytes = File.binread(staged[:path]).b.freeze
              selected_sha256 = staged.dig(:evidence, :selected_sha256).to_s.downcase
              unless selected_sha256.match?(/\A[0-9a-f]{64}\z/)
                selected_sha256 = Digest::SHA256.hexdigest(selected_bytes)
              end
              entry[:texture][:bytes] = selected_bytes
              entry[:texture][:byte_length] = selected_bytes.bytesize
              entry[:texture][:sha256] = selected_sha256.freeze
              PerformanceTrace.increment(:textures_staged, 1)
              if staged.dig(:evidence,:selected) == :semantic_colorized_native
                entry[:semantic_colorize_active]=true
                entry[:colorize_output_sha256]=staged.dig(:evidence,:output_pixel_sha256)
              end
              written += 1 if File.file?(staged[:path])
            else
              out_path = File.join(texture_dir, tex_filename)
              written += 1 if tex.write(out_path, true)
              entry[:texture][:staging_evidence] = { selected: :staged_png, path: out_path, staged_bytes: File.size(out_path) } if File.file?(out_path)
            end
            checkpoint.call(stage: :snapshot_textures, processed: index + 1, total: total, operation_label: mat.name, unit: 'material', force: true) if checkpoint
          rescue => e
            raise if e.class.ancestors.any? { |ancestor| ancestor.respond_to?(:name) && ancestor.name.to_s.end_with?('Cancelled', 'TranscodeCancelledError') }
            raise if e.class.name.to_s.end_with?('ModelChanged')
            if optimize_textures
              # An embedded SketchUp texture is authoritative even when its
              # original disk path points at another machine. Never silently
              # fall back to the stale external filename after staging fails.
              fallback_path = File.join(texture_dir, "#{safe_name}.fallback.png")
              begin
                rep = tex.image_rep(true)
                fallback_method = :image_rep_save
                begin
                  rep.save_file(fallback_path)
                  raise 'SketchUp ImageRep save produced no PNG' unless File.file?(fallback_path) && File.size(fallback_path).positive?
                rescue StandardError => save_error
                  # SketchUp can expose embedded pixels even when its native
                  # file serializer refuses to save the image. Encode those
                  # exact displayed pixels as lossless PNG; no stale source
                  # path or fabricated placeholder is permitted.
                  write_pixel_fallback_png(rep, fallback_path)
                  fallback_method = :raw_pixel_png
                end
                raise 'Displayed-pixel fallback could not be saved' unless File.file?(fallback_path) && File.size(fallback_path).positive?
                fallback_bytes = File.binread(fallback_path).b.freeze
                entry[:texture][:filename] = File.basename(fallback_path)
                entry[:texture][:bytes] = fallback_bytes
                entry[:texture][:byte_length] = fallback_bytes.bytesize
                entry[:texture][:sha256] = Digest::SHA256.hexdigest(fallback_bytes).freeze
                entry[:texture][:staging_evidence] = {
                  selected: :staged_png, reason: :displayed_pixel_fallback,
                  fallback_method: fallback_method,
                  original_error: "#{e.class}: #{e.message}",
                  selected_sha256: entry[:texture][:sha256]
                }
                written += 1
                checkpoint.call(stage: :snapshot_textures, processed: index + 1, total: total, operation_label: mat.name, unit: 'material', force: true) if checkpoint
              rescue StandardError => fallback_error
                raise ArgumentError, "Cannot capture embedded texture '#{mat.name}' (#{e.message}); displayed-pixel fallback failed: #{fallback_error.message}"
              end
            else
              Logger.warn("Could not write texture for '#{mat.name}': #{e.message}") if defined?(Logger)
            end
          end
        end

        results[index] = entry
      end

      checkpoint.call(stage: :snapshot_materials, processed: total, total: total) if checkpoint
      Logger.info("Wrote #{written} texture(s) to #{texture_dir}") if texture_dir && defined?(Logger)
      results
    end

  end
end
