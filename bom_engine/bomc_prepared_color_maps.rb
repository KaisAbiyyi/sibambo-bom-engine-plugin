# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'bomc_jpeg_color_map'

module BOMEngine
  # Opt-in reuse of browser-verified, host-captured JCM payloads. Every reuse
  # must match the current texture's original JPEG and displayed raw frame.
  # Material names and model paths do not participate in selection.
  class BOMCPreparedColorMaps
    MAX_REPORT_BYTES = 1_048_576
    MAX_PAYLOAD_BYTES = BOMCJpegColorMap::HEADER_BYTES + BOMCJpegColorMap::MAX_JPEG_BYTES + BOMCJpegColorMap::MAX_ENTRIES * 7

    def self.read_report(path)
      raise ArgumentError, 'Missing or oversized prepared-map report' unless File.file?(path) && File.size(path) <= MAX_REPORT_BYTES
      JSON.parse(File.binread(path))
    end

    def self.sha?(value)
      value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end

    def self.checked_file(root, relative, expected_sha, max_bytes:)
      unless relative.is_a?(String) && relative.match?(/\Atexture-\d+\.(?:native\.jpg|target\.raw|jcm)\z/) && sha?(expected_sha)
        raise ArgumentError, 'Invalid prepared-map file descriptor'
      end
      path = File.join(root, relative)
      prefix = File.realpath(root).tr('\\', '/').downcase + '/'
      unless File.file?(path) && !File.symlink?(path) && File.realpath(path).tr('\\', '/').downcase.start_with?(prefix) &&
          File.size(path) > 0 && File.size(path) <= max_bytes && Digest::SHA256.file(path).hexdigest == expected_sha
        raise ArgumentError, 'Prepared-map file changed or escaped directory'
      end
      path
    end

    def self.load(offline_report:, browser_report:)
      offline_path = File.expand_path(offline_report)
      browser_path = File.expand_path(browser_report)
      offline = read_report(offline_path)
      browser = read_report(browser_path)
      unless offline['schema'] == 'exact-color-map-offline-v1' && offline['status'] == 'captured_pending_browser_verification' &&
          offline['ready'] == false && offline['required_loader'] == 'bomc-next-jcm-v1' &&
          browser['schema'] == 'exact-color-map-browser-evidence-v1' && browser['status'] == 'sample_pixels_verified' &&
          browser['evidence_kind'] == 'runtime_capture' && browser['ready'] == false &&
          browser['capture_report_sha256'] == Digest::SHA256.file(offline_path).hexdigest &&
          browser['source_tree_sha256'] == offline['source_tree_sha256']
        raise ArgumentError, 'Prepared-map browser evidence is incomplete or unrelated'
      end
      relative_host = offline['raw_capture_file']
      unless relative_host.is_a?(String) && relative_host.match?(/\Apixels-[a-zA-Z0-9-]+\/report\.json\z/)
        raise ArgumentError, 'Invalid host capture path'
      end
      results_dir = File.dirname(File.dirname(offline_path))
      host_path = File.join(results_dir, relative_host)
      host = read_report(host_path)
      unless host['schema'] == 'exact-color-map-host-pixels-v1' && host['status'] == 'captured_pending_offline_verification' &&
          host['ready'] == false && host['source_tree_sha256'] == offline['source_tree_sha256'] &&
          host['required_loader'] == 'bomc-next-jcm-v1' &&
          offline['raw_capture_sha256'] == Digest::SHA256.file(host_path).hexdigest
        raise ArgumentError, 'Prepared-map host capture is incomplete or unrelated'
      end
      raw_rows = host['textures']
      encoded_rows = offline['textures']
      browser_rows = browser['textures']
      unless raw_rows.is_a?(Array) && (1..64).cover?(raw_rows.length) &&
          encoded_rows.is_a?(Array) && browser_rows.is_a?(Array) &&
          encoded_rows.length == raw_rows.length && browser_rows.length == raw_rows.length
        raise ArgumentError, 'Prepared-map texture count mismatch'
      end
      entries = raw_rows.each_index.map do |index|
        raw, encoded, checked = raw_rows[index], encoded_rows[index], browser_rows[index]
        width, height = raw.values_at('width', 'height')
        BOMCJpegColorMap.validate_dimensions(width, height)
        descriptor = raw.fetch('target_frame')
        bits, padding = descriptor.values_at('bits_per_pixel', 'row_padding')
        unless [24, 32].include?(bits) && padding.is_a?(Integer) && (0..3).cover?(padding) &&
            descriptor['width'] == width && descriptor['height'] == height && descriptor['row_order'] == 'top_down' &&
            descriptor['channel_layout'] == (bits == 24 ? 'BGR' : 'BGRA') &&
            descriptor['bytes'] == (width * (bits / 8) + padding) * height
          raise ArgumentError, 'Invalid prepared-map host frame'
        end
        native = raw.fetch('native_jpeg')
        host_dir = File.dirname(host_path)
        checked_file(host_dir, native.fetch('file'), native.fetch('sha256'), max_bytes: BOMCJpegColorMap::MAX_JPEG_BYTES)
        checked_file(host_dir, descriptor.fetch('file'), descriptor.fetch('sha256'), max_bytes: 128_100_000)
        file = encoded.fetch('file')
        unless file == checked['file'] && checked['status'] == 'verified' &&
            checked['sha256'] == encoded['sha256'] && checked['rgba_sha256'] == encoded['expected_rgba_sha256'] &&
            checked['width'] == width && checked['height'] == height &&
            encoded['width'] == width && encoded['height'] == height
          raise ArgumentError, 'Prepared-map browser texture does not match host'
        end
        path = checked_file(File.dirname(offline_path), file, encoded.fetch('sha256'), max_bytes: MAX_PAYLOAD_BYTES)
        bytes = File.binread(path)
        map = BOMCJpegColorMap.parse(bytes)
        unless encoded['bytes'] == bytes.bytesize && map[:width] == width && map[:height] == height &&
            map[:base_hash].unpack1('H*') == encoded['base_rgba_sha256'] &&
            map[:output_hash].unpack1('H*') == encoded['expected_rgba_sha256']
          raise ArgumentError, 'Prepared-map payload is not bound to browser pixels'
        end
        {width: width, height: height, native_sha256: native.fetch('sha256'),
          raw_sha256: descriptor.fetch('sha256'), bits: bits, padding: padding,
          payload_path: path, payload_sha256: encoded.fetch('sha256'), payload_bytes: bytes.bytesize,
          base_sha256: encoded.fetch('base_rgba_sha256'), output_sha256: encoded.fetch('expected_rgba_sha256'),
          jpeg_sha256: Digest::SHA256.hexdigest(map[:jpeg])}
      end
      new(entries)
    end

    def initialize(entries)
      @entries = entries.freeze
    end

    def stage(texture:, directory:, basename:, source_path:, budget:, image_rep_loader: nil, &checkpoint)
      return nil unless ['.jpg', '.jpeg'].include?(File.extname(source_path.to_s).downcase)
      matches = @entries.select { |entry| entry[:width] == texture.image_width && entry[:height] == texture.image_height }
      return nil if matches.empty?
      native_path = File.join(directory, "#{basename}.prepared-source.jpg")
      raise ArgumentError, 'Prepared native path already exists' if File.exist?(native_path)
      return nil unless texture.write(native_path, false) && File.file?(native_path)
      native_sha = Digest::SHA256.file(native_path).hexdigest
      matches.select! { |entry| entry[:native_sha256] == native_sha }
      return nil if matches.empty?
      reference = texture.image_rep(true)
      return nil unless reference.width == texture.image_width && reference.height == texture.image_height
      bits, padding = reference.bits_per_pixel, reference.row_padding
      return nil unless [24, 32].include?(bits) && padding.is_a?(Integer) && (0..3).cover?(padding)
      data = reference.data
      expected = (texture.image_width * (bits / 8) + padding) * texture.image_height
      return nil unless data.is_a?(String) && data.bytesize == expected
      raw_sha = Digest::SHA256.hexdigest(data)
      entry = matches.find { |item| item[:bits] == bits && item[:padding] == padding && item[:raw_sha256] == raw_sha }
      return nil unless entry
      checkpoint.call(0, texture.image_width * texture.image_height) if checkpoint

      if entry[:base_sha256] == entry[:output_sha256]
        loader = image_rep_loader || ->(path) { Sketchup::ImageRep.new(path) }
        measured = BOMCTextureOptimizer.compare(reference, loader.call(native_path), &checkpoint)
        if measured[:compatible] && measured[:alpha_preserved] && measured[:max_channel_error] == 0 && measured[:mean_squared_error] == 0.0
          return {path: native_path, filename: File.basename(native_path), evidence: {
            selected: :native_jpeg_candidate, policy_revision: 'adaptive-texture-3', profile: :exact,
            native_jpeg: true, selected_sha256: native_sha, candidate_media_type: :jpeg,
            candidate_bytes: File.size(native_path), quality: measured, alpha_preserved: true,
            reason: :verified_prepared_native_jpeg}}
        end
        return nil
      end

      pixels = texture.image_width * texture.image_height
      known = budget && budget.fetch(:hashes).key?(entry[:payload_sha256])
      return nil if budget && !known && pixels > budget.fetch(:remaining_pixels)
      path = File.join(directory, "#{basename}.jcm")
      raise ArgumentError, 'Prepared output path already exists' if File.exist?(path)
      bytes = File.binread(entry[:payload_path])
      raise ArgumentError, 'Prepared payload changed' unless bytes.bytesize == entry[:payload_bytes] && Digest::SHA256.hexdigest(bytes) == entry[:payload_sha256]
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY) { |file| file.write(bytes) }
      if budget && !known
        budget[:remaining_pixels] -= pixels
        budget[:hashes][entry[:payload_sha256]] = true
      end
      {path: path, filename: File.basename(path), evidence: {
        selected: :jpeg_color_map_candidate, policy_revision: 'exact-jcm-1', profile: :exact,
        native_jpeg: true, selected_sha256: entry[:payload_sha256],
        base_pixel_sha256: entry[:base_sha256], output_pixel_sha256: entry[:output_sha256],
        normalized_jpeg_sha256: entry[:jpeg_sha256], required_loader: 'bomc-next-jcm-v1',
        candidate_media_type: :jpeg_color_map, candidate_bytes: bytes.bytesize,
        quality: {compatible: true, mean_squared_error: 0.0, max_channel_error: 0, alpha_preserved: true},
        alpha_preserved: true, reason: :verified_prepared_color_map}}
    end
  end
end
