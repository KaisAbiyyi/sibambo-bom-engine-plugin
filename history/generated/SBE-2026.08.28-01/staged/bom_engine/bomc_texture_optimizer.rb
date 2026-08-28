# Evidence-gated texture staging for BOMC.
#
# SketchUp can retain a JPEG texture inside an SKP even when Texture#filename is
# no longer a readable filesystem path. Exporting every such texture as PNG can
# multiply its byte size. This module keeps PNG as the lossless fallback and
# accepts a JPEG candidate only when transparency, decoded quality, and measured
# byte savings all pass conservative gates.

module SibamboHistory
  module V20260828_01
  module BOMCTextureOptimizer
    GENERAL_MIN_PSNR_DB = 42.0
    NATIVE_JPEG_MIN_PSNR_DB = 38.0
    MIN_SAVINGS_BYTES = 4_096
    MIN_SAVINGS_RATIO = 0.10
    CHECKPOINT_PIXELS = 32_768

    module_function

    def native_jpeg_path?(path)
      ['.jpg', '.jpeg'].include?(File.extname(path.to_s).downcase)
    end

    def opaque?(image_rep, &checkpoint)
      frame = frame_for(image_rep)
      return true if frame[:channels] == 3
      return false unless frame[:channels] == 4

      width = frame[:width]
      height = frame[:height]
      stride = frame[:stride]
      data = frame[:data]
      processed = 0
      row = 0
      while row < height
        offset = row * stride + 3
        column = 0
        while column < width
          return false unless data.getbyte(offset) == 255
          offset += 4
          column += 1
          processed += 1
          checkpoint.call(processed, width * height) if checkpoint && (processed % CHECKPOINT_PIXELS).zero?
        end
        row += 1
      end
      true
    rescue ArgumentError, TypeError
      false
    end

    def compare(reference, candidate, &checkpoint)
      source = frame_for(reference)
      encoded = frame_for(candidate)
      unless source[:width] == encoded[:width] && source[:height] == encoded[:height]
        return { compatible: false, reason: :dimension_mismatch }
      end
      unless [3, 4].include?(source[:channels]) && [3, 4].include?(encoded[:channels])
        return { compatible: false, reason: :unsupported_pixel_layout }
      end

      width = source[:width]
      height = source[:height]
      squared_error = 0
      maximum_error = 0
      processed = 0
      row = 0
      while row < height
        source_offset = row * source[:stride]
        encoded_offset = row * encoded[:stride]
        column = 0
        while column < width
          channel = 0
          while channel < 3
            error = source[:data].getbyte(source_offset + channel) - encoded[:data].getbyte(encoded_offset + channel)
            absolute_error = error.abs
            maximum_error = absolute_error if absolute_error > maximum_error
            squared_error += error * error
            channel += 1
          end
          source_offset += source[:channels]
          encoded_offset += encoded[:channels]
          column += 1
          processed += 1
          checkpoint.call(processed, width * height) if checkpoint && (processed % CHECKPOINT_PIXELS).zero?
        end
        row += 1
      end

      samples = width * height * 3
      mean_squared_error = squared_error.to_f / samples
      psnr = if mean_squared_error.zero?
               Float::INFINITY
             else
               10.0 * Math.log10((255.0 * 255.0) / mean_squared_error)
             end
      {
        compatible: true,
        width: width,
        height: height,
        samples: samples,
        mean_squared_error: mean_squared_error,
        psnr_db: psnr,
        max_channel_error: maximum_error
      }
    rescue ArgumentError, TypeError => error
      { compatible: false, reason: :invalid_pixel_data, error: error.message }
    end

    def select(staged_path:, candidate_path:, reference:, candidate:, native_jpeg: false, &checkpoint)
      staged_bytes = File.file?(staged_path) ? File.size(staged_path) : nil
      candidate_bytes = File.file?(candidate_path) ? File.size(candidate_path) : nil
      raise ArgumentError, 'lossless staged texture is missing' if staged_bytes.nil?

      base = {
        path: staged_path,
        selected: :staged_png,
        staged_bytes: staged_bytes,
        candidate_bytes: candidate_bytes,
        native_jpeg: !!native_jpeg,
        candidate_media_type: :jpeg,
        browser_decode_compatible: true
      }
      return base.merge(reason: :jpeg_candidate_unavailable) if candidate_bytes.nil?
      return base.merge(reason: :alpha_requires_lossless) unless opaque?(reference, &checkpoint)

      quality = compare(reference, candidate, &checkpoint)
      return base.merge(reason: :candidate_decode_incompatible, quality: quality) unless quality[:compatible]

      savings_bytes = staged_bytes - candidate_bytes
      savings_ratio = savings_bytes.to_f / staged_bytes
      threshold = native_jpeg ? NATIVE_JPEG_MIN_PSNR_DB : GENERAL_MIN_PSNR_DB
      unless quality[:psnr_db] >= threshold
        return base.merge(
          reason: :quality_gate_failed,
          quality: quality,
          quality_threshold_psnr_db: threshold,
          savings_bytes: savings_bytes,
          savings_ratio: savings_ratio
        )
      end
      unless savings_bytes >= MIN_SAVINGS_BYTES && savings_ratio >= MIN_SAVINGS_RATIO
        return base.merge(
          reason: :insufficient_byte_savings,
          quality: quality,
          quality_threshold_psnr_db: threshold,
          savings_bytes: savings_bytes,
          savings_ratio: savings_ratio
        )
      end

      base.merge(
        path: candidate_path,
        selected: :jpeg_candidate,
        reason: native_jpeg ? :native_jpeg_restored : :high_quality_jpeg_smaller,
        quality: quality,
        quality_threshold_psnr_db: threshold,
        savings_bytes: savings_bytes,
        savings_ratio: savings_ratio,
        alpha_preserved: true
      )
    end

    def stage(texture:, directory:, basename:, source_path:, image_rep_loader: nil, &checkpoint)
      png_path = File.join(directory, "#{basename}.png")
      raise 'SketchUp could not stage the lossless PNG texture' unless texture.write(png_path, true) && File.file?(png_path)

      reference = texture.image_rep(true)
      native_jpeg = native_jpeg_path?(source_path)
      evidence = {
        path: png_path,
        selected: :staged_png,
        staged_bytes: File.size(png_path),
        candidate_bytes: nil,
        native_jpeg: native_jpeg,
        reason: :jpeg_not_evaluated
      }

      if opaque?(reference, &checkpoint)
        jpeg_path = File.join(directory, "#{basename}.jpg")
        reference.save_file(jpeg_path)
        if File.file?(jpeg_path)
          loader = image_rep_loader || lambda { |path| Sketchup::ImageRep.new(path) }
          candidate = loader.call(jpeg_path)
          evidence = select(
            staged_path: png_path,
            candidate_path: jpeg_path,
            reference: reference,
            candidate: candidate,
            native_jpeg: native_jpeg,
            &checkpoint
          )
        else
          evidence = evidence.merge(reason: :jpeg_write_failed)
        end
      else
        evidence = evidence.merge(reason: :alpha_requires_lossless)
      end

      {
        path: evidence[:path],
        filename: File.basename(evidence[:path]),
        evidence: evidence.reject { |key, _value| key == :path }
      }
    rescue StandardError => error
      raise if cancellation_error?(error)
      if defined?(png_path) && File.file?(png_path)
        {
          path: png_path,
          filename: File.basename(png_path),
          evidence: {
            selected: :staged_png,
            staged_bytes: File.size(png_path),
            reason: :optimizer_error,
            error: "#{error.class}: #{error.message}"
          }
        }
      else
        raise
      end
    end

    def cancellation_error?(error)
      error.class.ancestors.any? do |ancestor|
        name = ancestor.respond_to?(:name) ? ancestor.name.to_s : ''
        name == 'SibamboHistory::V20260828_01::ConversionJob::Cancelled' ||
          name == 'SibamboHistory::V20260828_01::BOMCProcessing::Cancelled' ||
          name.end_with?('::Cancelled') ||
          name == 'Cancelled'
      end
    end
    private_class_method :cancellation_error?

    def frame_for(image_rep)
      width = Integer(image_rep.width)
      height = Integer(image_rep.height)
      bits_per_pixel = Integer(image_rep.bits_per_pixel)
      row_padding = Integer(image_rep.row_padding)
      channels = bits_per_pixel / 8
      data = image_rep.data
      raise ArgumentError, 'image dimensions must be positive' unless width > 0 && height > 0
      raise ArgumentError, 'unsupported image pixel layout' unless [3, 4].include?(channels)
      raise TypeError, 'image pixel data must be a String' unless data.is_a?(String)
      stride = width * channels + row_padding
      raise ArgumentError, 'image pixel data is truncated' if data.bytesize < stride * height
      {
        width: width,
        height: height,
        channels: channels,
        stride: stride,
        data: data
      }
    end
    private_class_method :frame_for
  end
end

end # SibamboHistory
