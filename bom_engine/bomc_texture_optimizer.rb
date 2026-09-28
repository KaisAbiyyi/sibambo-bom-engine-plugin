# frozen_string_literal: true
# Evidence-gated texture staging and multi-candidate frontier for BOMC.
#
# Generates and evaluates candidate encodings (PNG lossless, JPEG, WebP)
# subject to semantic quality gates (PSNR), transparency preservation,
# minimum byte savings, and cooperative export cancellation.

require 'digest'
require 'fileutils'
require_relative 'bomc_texture_policy'
require_relative 'bomc_texture_encoder'
require_relative 'bomc_candidate'
require_relative 'bomc_jpeg_color_map'

module BOMEngine
  module BOMCTextureOptimizer
    MIN_SAVINGS_BYTES = 4_096
    MIN_SAVINGS_RATIO = 0.10
    CHECKPOINT_PIXELS = 32_768
    WEBP_QUALITIES = [80, 90, 95, 100].freeze
    MAX_ADAPTIVE_PIXELS = 32_000_000
    POLICY_REVISION = 'adaptive-texture-4'.freeze
    LOSSLESS_SEARCH_REVISION = 'exact-webp-m4q75-m6q100mt-1'.freeze

    module_function

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
    end
    private_class_method :monotonic_ms

    def measure_phase(timings, key)
      started = monotonic_ms
      yield
    ensure
      timings[key] = (monotonic_ms - started).round(3)
    end
    private_class_method :measure_phase

    def stage_result(evidence, timings, started)
      evidence = evidence.merge(timings_ms: timings.merge(total: (monotonic_ms - started).round(3)))
      { path: evidence[:path], filename: File.basename(evidence[:path]),
        evidence: evidence.reject { |key, _value| key == :path } }
    end
    private_class_method :stage_result

    def reference_pixel_sha256(image_rep)
      frame = frame_for(image_rep)
      digest = Digest::SHA256.new
      digest.update([frame[:width], frame[:height], frame[:channels], frame[:stride]].pack('L<4'))
      digest.update(frame[:data])
      digest.hexdigest
    end
    private_class_method :reference_pixel_sha256

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
      alpha_preserved = true
      processed = 0
      row = 0
      while row < height
        source_offset = row * source[:stride]
        encoded_offset = row * encoded[:stride]
        column = 0
        while column < width
          # Lossless candidates commonly have identical pixel blocks. Compare
          # those bytes in native String code, excluding each row's padding.
          # Differing layouts/blocks still take the complete numeric path below.
          if source[:channels] == encoded[:channels] && (column % CHECKPOINT_PIXELS).zero?
            count = [width - column, CHECKPOINT_PIXELS].min
            length = count * source[:channels]
            if source[:data].byteslice(source_offset, length) == encoded[:data].byteslice(encoded_offset, length)
              previous_processed = processed
              processed += count
              column += count
              source_offset += length
              encoded_offset += length
              if checkpoint && processed / CHECKPOINT_PIXELS > previous_processed / CHECKPOINT_PIXELS
                checkpoint.call(processed, width * height)
              end
              next
            end
          end
          source_alpha = source[:channels] == 4 ? source[:data].getbyte(source_offset + 3) : 255
          encoded_alpha = encoded[:channels] == 4 ? encoded[:data].getbyte(encoded_offset + 3) : 255
          alpha_preserved &&= source_alpha == encoded_alpha
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
        max_channel_error: maximum_error,
        alpha_preserved: alpha_preserved
      }
    rescue ArgumentError, TypeError => error
      { compatible: false, reason: :invalid_pixel_data, error: error.message }
    end

    def select(staged_path:, candidate_path:, reference:, candidate:, native_jpeg: false, profile: :visual, semantic_class: :class_b, measured_quality: nil, &checkpoint)
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

      quality = measured_quality || compare(reference, candidate, &checkpoint)
      return base.merge(reason: :candidate_decode_incompatible, quality: quality) unless quality[:compatible]

      savings_bytes = staged_bytes - candidate_bytes
      savings_ratio = savings_bytes.to_f / staged_bytes
      threshold = BOMCTexturePolicy.min_psnr(profile: profile, semantic_class: semantic_class, native_jpeg: native_jpeg)
      unless quality[:alpha_preserved] && quality[:psnr_db] >= threshold
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

    def stage(texture:, directory:, basename:, source_path:, profile: :visual, semantic_class: :class_b, policy: nil, image_rep_loader: nil, allow_jpeg_color_map: false, color_map_budget: nil, prepared_color_maps: nil, candidate_cache: nil, &checkpoint)
      stage_started = monotonic_ms
      timings = {}
      png_path = File.join(directory, "#{basename}.png")
      if allow_jpeg_color_map == true && profile.to_s == 'exact' && prepared_color_maps
        prepared = measure_phase(timings, :prepared_color_map) do
          prepared_color_maps.stage(texture: texture, directory: directory, basename: basename,
            source_path: source_path, budget: color_map_budget, image_rep_loader: image_rep_loader, &checkpoint)
        end
        return stage_result(prepared.fetch(:evidence).merge(path: prepared.fetch(:path)), timings, stage_started) if prepared
      end
      written = measure_phase(timings, :png_write) { texture.write(png_path, true) }
      raise 'SketchUp could not stage the lossless PNG texture' unless written && File.file?(png_path)

      reference = measure_phase(timings, :reference_image_rep) { texture.image_rep(true) }
      native_jpeg = native_jpeg_path?(source_path)
      is_pixel_lossless = (policy == :pixel_lossless || profile.to_s.downcase.to_sym == :exact)

      evidence = {
        path: png_path,
        selected: :staged_png,
        staged_bytes: File.size(png_path),
        candidate_bytes: nil,
        native_jpeg: native_jpeg,
        reason: is_pixel_lossless ? :pixel_lossless_policy : :jpeg_not_evaluated
      }

      loader = image_rep_loader || lambda { |path| Sketchup::ImageRep.new(path) }

      # Exact is a pixel contract, not a PNG-only container policy. Compete
      # lossless encodings, but never construct a lossy JPEG/WebP candidate.
      if is_pixel_lossless
        if native_jpeg
          evidence = measure_phase(timings, :native_jpeg_evaluation) do
            select_native_jpeg(texture, png_path, reference, evidence, loader, &checkpoint)
          end
        end
        evidence = measure_phase(timings, :webp_search) do
          adaptive_webp(png_path, reference, evidence, loader, profile,
            semantic_class, native_jpeg, pixel_lossless: true,
            expanded_lossless_search: allow_jpeg_color_map == true, candidate_cache: candidate_cache, &checkpoint)
        end
        if allow_jpeg_color_map == true && profile.to_s == 'exact' && native_jpeg
          evidence = measure_phase(timings, :color_map_evaluation) do
            select_color_map(texture, png_path, reference, evidence, loader, color_map_budget, &checkpoint)
          end
        end
        return stage_result(evidence, timings, stage_started)
      end

      if measure_phase(timings, :opacity_check) { opaque?(reference, &checkpoint) }
        begin
          evidence = measure_phase(timings, :jpeg_evaluation) do
            jpeg_path = File.join(directory, "#{basename}.jpg")
            reference.save_file(jpeg_path)
            if File.file?(jpeg_path)
              jpeg_quality = nil
              if candidate_cache
                key = [reference_pixel_sha256(reference), Digest::SHA256.file(jpeg_path).hexdigest].join(':')
                jpeg_quality = candidate_cache.fetch(:jpeg_quality, {})[key]&.dup
                candidate_cache[:jpeg_quality_hits] = candidate_cache.fetch(:jpeg_quality_hits, 0) + 1 if jpeg_quality
              end
              candidate = loader.call(jpeg_path) unless jpeg_quality
              jpeg_quality ||= compare(reference, candidate, &checkpoint)
              candidate_cache[:jpeg_quality] ||= {} if candidate_cache
              candidate_cache[:jpeg_quality][key] = jpeg_quality.dup if candidate_cache && jpeg_quality[:compatible]
              select(
                staged_path: png_path,
                candidate_path: jpeg_path,
                reference: reference,
                candidate: candidate,
                measured_quality: jpeg_quality,
                native_jpeg: native_jpeg,
                profile: profile,
                semantic_class: semantic_class,
                &checkpoint
              )
            else
              evidence.merge(reason: :jpeg_write_failed)
            end
          end
        rescue StandardError => error
          raise if cancellation_error?(error)
          evidence = evidence.merge(reason: :jpeg_error, error: "#{error.class}: #{error.message}")
        end
      else
        evidence = evidence.merge(reason: :alpha_requires_lossless)
      end

      evidence = measure_phase(timings, :webp_search) do
        adaptive_webp(png_path, reference, evidence, loader, profile, semantic_class, native_jpeg,
          candidate_cache: candidate_cache, &checkpoint)
      end
      stage_result(evidence, timings, stage_started)
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
            error: "#{error.class}: #{error.message}",
            timings_ms: timings.merge(total: (monotonic_ms - stage_started).round(3))
          }
        }
      else
        raise
      end
    end

    def select_native_jpeg(texture, png_path, reference, baseline, loader, &checkpoint)
      path = png_path.sub(/\.png\z/i, '.native.jpg')
      unless texture.write(path, false) && File.file?(path) && File.size(path) > 0
        return baseline.merge(reason: :native_jpeg_unavailable)
      end
      bytes = File.size(path)
      return baseline.merge(reason: :native_jpeg_not_smaller) if bytes >= File.size(png_path)
      measured = compare(reference, loader.call(path), &checkpoint)
      unless measured[:compatible] == true && measured[:alpha_preserved] == true &&
          measured[:max_channel_error] == 0 && measured[:mean_squared_error] == 0.0
        return baseline.merge(reason: :native_jpeg_pixel_mismatch, rejected_native_quality: measured)
      end
      baseline.merge(path: path, selected: :native_jpeg_candidate, candidate_media_type: :jpeg,
        candidate_bytes: bytes, reason: :pixel_identical_native_jpeg, quality: measured,
        alpha_preserved: true, savings_bytes: File.size(png_path) - bytes,
        savings_ratio: 1.0 - bytes.to_f / File.size(png_path))
    rescue StandardError => error
      raise if cancellation_error?(error)
      baseline.merge(reason: :native_jpeg_error, error: "#{error.class}: #{error.message}")
    end
    private_class_method :select_native_jpeg

    # Opt-in preview only. Existing export menus never request this capability.
    # Conversion is based on texture pixels, never model/material names.
    def select_color_map(texture, png_path, reference, baseline, loader, budget = nil, &checkpoint)
      attempts = Array(baseline[:attempts]).dup
      # No reconstruction dependency for pixels already preserved by native JPEG.
      # Reserve the mapped-pixel budget for textures which need colorization.
      return baseline if baseline[:selected] == :native_jpeg_candidate
      return baseline unless RUBY_PLATFORM.match?(/mingw|mswin/i)
      return baseline if reference.width * reference.height > MAX_ADAPTIVE_PIXELS
      return baseline unless opaque?(reference, &checkpoint)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      bounded = lambda do |processed, total|
        checkpoint.call(processed,total) if checkpoint
        raise 'Exact color-map time budget exceeded' if Process.clock_gettime(Process::CLOCK_MONOTONIC)-started > 30.0
      end
      native_path = png_path.sub(/\.png\z/i,'.native.jpg')
      unless File.file?(native_path) && File.size(native_path) > 0
        return baseline unless texture.write(native_path,false) && File.file?(native_path)
      end
      return baseline if File.size(native_path) > BOMCJpegColorMap::MAX_JPEG_BYTES
      jpeg = BOMCJpegColorMap.normalize_jpeg(File.binread(native_path),reference.width,reference.height)
      normalized_path = png_path.sub(/\.png\z/i,'.jcm-base.jpg')
      File.binwrite(normalized_path,jpeg)
      normalized = loader.call(normalized_path)
      base = color_map_rgba(normalized,&bounded)
      target = color_map_rgba(reference,&bounded)
      return baseline unless normalized.width == reference.width && normalized.height == reference.height
      bytes = BOMCJpegColorMap.encode(jpeg:jpeg,base_rgba:base,target_rgba:target,width:reference.width,height:reference.height,&bounded)
      unless bytes && bytes.bytesize < File.size(baseline[:path])
        return baseline.merge(attempts:attempts + [{codec: :jpeg_color_map,reason:bytes ? :not_smaller : :not_encodable,bytes:bytes&.bytesize}])
      end
      digest = Digest::SHA256.hexdigest(bytes)
      pixels = reference.width * reference.height
      if budget && !budget.fetch(:hashes).key?(digest) && pixels > budget.fetch(:remaining_pixels)
        return baseline.merge(attempts: attempts + [{codec: :jpeg_color_map, reason: :aggregate_pixel_budget}])
      end
      path = png_path.sub(/\.png\z/i,'.jcm')
      File.binwrite(path,bytes)
      if budget && !budget[:hashes].key?(digest)
        budget[:remaining_pixels] -= pixels
        budget[:hashes][digest] = true
      end
      baseline.merge(path:path,selected: :jpeg_color_map_candidate,candidate_media_type: :jpeg_color_map,
        reason: :verified_color_map_smaller,candidate_bytes:bytes.bytesize,selected_sha256:Digest::SHA256.hexdigest(bytes),
        policy_revision:'exact-jcm-1',base_pixel_sha256:Digest::SHA256.hexdigest(base),output_pixel_sha256:Digest::SHA256.hexdigest(target),
        normalized_jpeg_sha256:Digest::SHA256.hexdigest(jpeg),required_loader:'bomc-next-jcm-v1',
        quality:{compatible:true,mean_squared_error:0.0,max_channel_error:0,psnr_db:nil,alpha_preserved:true},
        alpha_preserved:true,savings_bytes:File.size(png_path)-bytes.bytesize,savings_ratio:1.0-bytes.bytesize.to_f/File.size(png_path),
        attempts:attempts + [{codec: :jpeg_color_map,reason: :accepted,bytes:bytes.bytesize}])
    rescue StandardError => error
      raise if cancellation_error?(error)
      baseline.merge(attempts:attempts + [{codec: :jpeg_color_map,reason: :candidate_error,error:"#{error.class}: #{error.message}"}])
    end
    private_class_method :select_color_map

    def color_map_rgba(image, &checkpoint)
      frame = frame_for(image)
      BOMCJpegColorMap.validate_dimensions(frame[:width],frame[:height])
      bytes = +''.b
      processed = 0
      total = frame[:width] * frame[:height]
      checkpoint.call(0, total) if checkpoint
      frame[:height].times do |row|
        offset = row * frame[:stride]
        frame[:width].times do
          bytes << frame[:data].getbyte(offset+2) << frame[:data].getbyte(offset+1) << frame[:data].getbyte(offset)
          bytes << (frame[:channels] == 4 ? frame[:data].getbyte(offset+3) : 255)
          offset += frame[:channels]
          processed += 1
          checkpoint.call(processed, total) if checkpoint && ((processed % CHECKPOINT_PIXELS).zero? || processed == total)
        end
      end
      bytes
    end
    private_class_method :color_map_rgba

    # Bounded search over codecs/quality, independent of model names. Every
    # candidate is encoded from the original PNG, never from another candidate.
    # Choose the smallest measured candidate satisfying the unchanged contract.
    def adaptive_webp(png_path, reference, baseline, loader, profile, semantic_class, native_jpeg,
      pixel_lossless: false, expanded_lossless_search: false, candidate_cache: nil, &checkpoint)
      attempts = [baseline.reject { |key, _| key == :path }]
      best = if baseline[:path] == png_path
               baseline.merge(quality: { compatible: true, mean_squared_error: 0.0,
                 max_channel_error: 0, psnr_db: nil, alpha_preserved: true },
                 alpha_preserved: true, candidate_media_type: :png, candidate_bytes: File.size(png_path),
                 savings_bytes: 0, savings_ratio: 0.0)
             else
               baseline
             end
      search_timings = {}
      caps = measure_phase(search_timings, :encoder_capabilities) { BOMCTextureEncoder.capabilities(require_verified: true) }
      source_sha256 = measure_phase(search_timings, :source_sha256) { Digest::SHA256.file(png_path).hexdigest }
      reference_sha256 = if candidate_cache
                           measure_phase(search_timings, :reference_pixel_sha256) { reference_pixel_sha256(reference) }
                         end
      if !caps[:available] || !caps[:verified]
        attempts << { reason: :verified_encoder_unavailable }
      elsif reference.width * reference.height > MAX_ADAPTIVE_PIXELS
        attempts << { reason: :adaptive_pixel_limit }
      else
        # Lossless competes with PNG; lossy is restricted to opaque textures.
        variants = [{ mode: :lossless, quality: 75, label: 'm4-q75',
          options: { lossless_method: 4, lossless_quality: 75, multithreaded: false } }]
        if pixel_lossless && expanded_lossless_search
          variants << { mode: :lossless, quality: 100, label: 'm6-q100-mt',
            options: { lossless_method: 6, lossless_quality: 100, multithreaded: true } }
        end
        variants += WEBP_QUALITIES.map { |q| { mode: :lossy, quality: q, label: "q#{q}", options: {} } } if !pixel_lossless && opaque?(reference, &checkpoint)
        threshold = BOMCTexturePolicy.min_psnr(profile: profile, semantic_class: semantic_class, native_jpeg: native_jpeg)
        variants.each do |variant|
          mode = variant[:mode]
          quality_level = variant[:quality]
          encoder_options = variant[:options]
          candidate_path = png_path.sub(/\.png\z/i, ".#{mode}-#{variant[:label]}.webp")
          decoded_path = "#{candidate_path}.decoded.png"
          attempt = { codec: :webp, mode: mode, quality_level: quality_level, variant: variant[:label],
            encoder_options: encoder_options.merge(exact: mode == :lossless), encoder_sha256: caps[:sha256],
            policy_revision: LOSSLESS_SEARCH_REVISION, timings_ms: {} }
          attempt_started = monotonic_ms
          callback = checkpoint && lambda { |**_event| checkpoint.call(0, reference.width * reference.height) }
          begin
            cache_key, cache_hit = measure_phase(attempt[:timings_ms], :cache_lookup) do
              key = candidate_cache && Digest::SHA256.hexdigest(
                [source_sha256, caps[:sha256].to_s, mode, quality_level, encoder_options[:lossless_method],
                  encoder_options[:lossless_quality], encoder_options[:multithreaded], mode == :lossless,
                  POLICY_REVISION, LOSSLESS_SEARCH_REVISION].join("\0"))
              [key, key && fetch_cached_webp(candidate_cache, key, candidate_path)]
            end
            attempt[:cache_hit] = !!cache_hit
            encoded = if cache_hit
                        { success: true, path: candidate_path }
                      else
                        measure_phase(attempt[:timings_ms], :encode) do
                          BOMCTextureEncoder.encode_webp(source_path: png_path, output_path: candidate_path,
                            quality: quality_level, lossless: mode == :lossless,
                            lossless_method: encoder_options[:lossless_method],
                            lossless_quality: encoder_options[:lossless_quality],
                            multithreaded: encoder_options[:multithreaded], checkpoint: callback)
                        end
                      end
            unless encoded[:success]
              attempts << attempt.merge(reason: encoded[:reason], error: encoded[:error])
              next
            end
            if cache_key && !cache_hit
              measure_phase(attempt[:timings_ms], :cache_store) { store_cached_webp(candidate_cache, cache_key, candidate_path) }
            end
            bytes = File.size(candidate_path)
            attempt[:bytes] = bytes
            if bytes >= File.size(best[:path])
              attempts << attempt.merge(reason: :not_smaller)
              next
            end
            entry = cache_key && candidate_cache.fetch(:entries)[cache_key]
            cached_quality = if cache_hit && entry && entry[:quality_reference_sha256] == reference_sha256 &&
                entry[:quality_candidate_sha256] == entry[:sha256] && entry[:quality].is_a?(Hash)
                               entry[:quality].dup
                             end
            attempt[:quality_cache_hit] = !cached_quality.nil?
            if cached_quality
              candidate_cache[:quality_hits] = candidate_cache.fetch(:quality_hits, 0) + 1
              measured = cached_quality
            else
              decoded = measure_phase(attempt[:timings_ms], :decode) do
                BOMCTextureEncoder.decode_webp(source_path: candidate_path, output_path: decoded_path, checkpoint: callback)
              end
              unless decoded[:success]
                attempts << attempt.merge(reason: decoded[:reason])
                next
              end
              candidate_image = measure_phase(attempt[:timings_ms], :candidate_image_rep) { loader.call(decoded_path) }
              measured = measure_phase(attempt[:timings_ms], :pixel_compare) { compare(reference, candidate_image, &checkpoint) }
              if entry && measured[:compatible]
                entry[:quality_reference_sha256] = reference_sha256
                entry[:quality_candidate_sha256] = entry[:sha256]
                entry[:quality] = measured.dup
              end
            end
            reason = if !measured[:compatible]
                       :decode_incompatible
                     elsif !measured[:alpha_preserved]
                       :alpha_mismatch
                     elsif mode == :lossless && measured[:max_channel_error] != 0
                       :lossless_pixel_mismatch
                     elsif measured[:psnr_db] < threshold
                       :quality_gate_failed
                     else
                       :accepted
                     end
            attempts << attempt.merge(reason: reason, quality: measured)
            next unless reason == :accepted
            best = baseline.merge(path: candidate_path, selected: :webp_candidate, candidate_media_type: :webp,
              candidate_bytes: bytes, reason: :measured_webp_smaller, quality: measured,
              quality_threshold_psnr_db: threshold, alpha_preserved: true,
              savings_bytes: File.size(png_path) - bytes, savings_ratio: 1.0 - bytes.to_f / File.size(png_path))
            # Higher lossy qualities are not needed once the measured floor is met.
            break if mode == :lossy
          rescue StandardError => error
            raise if cancellation_error?(error)
            attempts << attempt.merge(reason: :candidate_error, error: "#{error.class}: #{error.message}")
          ensure
            attempt[:timings_ms][:total] = (monotonic_ms - attempt_started).round(3)
            File.delete(decoded_path) if File.file?(decoded_path)
          end
        end
      end
      json_safe_evidence(best.merge(attempts: attempts, policy_revision: POLICY_REVISION,
        lossless_search_revision: LOSSLESS_SEARCH_REVISION,
        semantic_class: semantic_class, profile: profile, encoder_sha256: caps[:sha256],
        source_sha256: source_sha256, webp_setup_timings_ms: search_timings,
        selected_sha256: Digest::SHA256.file(best[:path]).hexdigest))
    end
    private_class_method :adaptive_webp

    def fetch_cached_webp(cache, key, destination)
      entry = cache.fetch(:entries)[key]
      return false unless entry
      path = File.join(cache.fetch(:directory), "#{key}.webp")
      return false unless File.file?(path) && File.size(path) == entry[:bytes] &&
        Digest::SHA256.file(path).hexdigest == entry[:sha256]
      FileUtils.cp(path, destination)
      cache[:hits] = cache.fetch(:hits, 0) + 1
      true
    rescue IOError, SystemCallError
      false
    end
    private_class_method :fetch_cached_webp

    def store_cached_webp(cache, key, source)
      path = File.join(cache.fetch(:directory), "#{key}.webp")
      FileUtils.cp(source, path)
      cache.fetch(:entries)[key] = { bytes: File.size(path), sha256: Digest::SHA256.file(path).hexdigest }
    rescue IOError, SystemCallError
      # A cache write must never change which validated candidate is selected.
      nil
    end
    private_class_method :store_cached_webp

    def json_safe_evidence(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), result| result[k] = json_safe_evidence(v) }
      when Array then value.map { |v| json_safe_evidence(v) }
      when Float then value.finite? ? value : nil # zero MSE records losslessness without JSON Infinity
      else value
      end
    end
    private_class_method :json_safe_evidence

    def cancellation_error?(error)
      error.class.ancestors.any? do |ancestor|
        name = ancestor.respond_to?(:name) ? ancestor.name.to_s : ''
        name == 'BOMEngine::ConversionJob::Cancelled' ||
          name == 'BOMEngine::BOMCProcessing::Cancelled' ||
          name.end_with?('::Cancelled', '::TranscodeCancelledError') ||
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
      raise ArgumentError, 'unsupported image pixel layout' unless [24, 32].include?(bits_per_pixel) && row_padding >= 0
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
