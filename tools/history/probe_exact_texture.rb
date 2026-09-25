# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'securerandom'
require 'time'
require 'zlib'

# Read-only with respect to the model and installed extensions. This measures
# whether SketchUp can extract its embedded JPEG without changing decoded pixels.
# It does not export a model, run codecs, install anything or certify a release.
module ExactTextureProbe
  MAX_PIXELS = 4_000_000
  HARD_MAX_PIXELS = 32_000_000
  DEFAULT_ROOT = File.expand_path('../../../scratch/exact-texture-probe', __dir__)
  module_function

  def frame(image)
    width, height = Integer(image.width), Integer(image.height)
    bits, padding = Integer(image.bits_per_pixel), Integer(image.row_padding)
    bytes = image.data
    raise ArgumentError, 'Invalid image layout' unless width > 0 && height > 0 &&
      width * height <= HARD_MAX_PIXELS && [24, 32].include?(bits) && padding >= 0 && bytes.is_a?(String)
    channels = bits / 8
    stride = width * channels + padding
    raise ArgumentError, 'Truncated image pixels' unless bytes.bytesize >= stride * height
    [width, height, channels, stride, bytes]
  end

  def same_pixels?(reference, candidate)
    width, height, channels, stride, bytes = frame(reference)
    other_width, other_height, other_channels, other_stride, other = frame(candidate)
    return false unless width == other_width && height == other_height
    height.times do |row|
      a, b = row * stride, row * other_stride
      if channels == other_channels
        return false unless bytes.byteslice(a, width * channels) == other.byteslice(b, width * channels)
        next
      end
      width.times do
        return false unless bytes.byteslice(a, 3) == other.byteslice(b, 3)
        alpha = channels == 4 ? bytes.getbyte(a + 3) : 255
        other_alpha = other_channels == 4 ? other.getbyte(b + 3) : 255
        return false unless alpha == other_alpha
        a += channels
        b += other_channels
      end
    end
    true
  end

  # Preserve the actual host-decoded bytes, not merely a Boolean verdict.
  # This lets follow-up comparisons/codecs run offline without another export.
  def save_pixels(image, session, filename)
    width, height, channels, stride, bytes = frame(image)
    bytes = bytes.byteslice(0, stride * height)
    Zlib::GzipWriter.open(File.join(session, filename)) { |gz| gz.write(bytes) }
    { file: filename, width: width, height: height, bits_per_pixel: channels * 8,
      row_padding: stride - width * channels, raw_bytes: bytes.bytesize,
      raw_sha256: Digest::SHA256.hexdigest(bytes),
      gzip_sha256: Digest::SHA256.file(File.join(session, filename)).hexdigest }
  end

  def run(model: nil, output_root: DEFAULT_ROOT, loader: nil, limit: 1, capture_pixels: true,
      min_pixels: 1, max_pixels: MAX_PIXELS)
    unless min_pixels.is_a?(Integer) && max_pixels.is_a?(Integer) &&
        min_pixels > 0 && min_pixels <= max_pixels && max_pixels <= HARD_MAX_PIXELS
      raise ArgumentError, 'Pixel range must be within 1..32000000'
    end
    maximum = capture_pixels ? 3 : 64
    raise ArgumentError, "Limit must be 1..#{maximum}" unless limit.is_a?(Integer) && (1..maximum).cover?(limit)
    model ||= Sketchup.active_model if defined?(Sketchup)
    raise 'Open a saved model without unsaved edits first.' unless model &&
      File.file?(model.path.to_s) && !model.modified?
    loader ||= ->(path) { Sketchup::ImageRep.new(path) }
    skipped_large = 0
    eligible = model.materials.map do |material|
      texture = material.texture
      next unless texture && %w[.jpg .jpeg].include?(File.extname(texture.filename.to_s).downcase)
      width, height = texture.image_width.to_i, texture.image_height.to_i
      pixels = width * height
      if pixels > max_pixels
        skipped_large += 1
        next
      end
      next unless width > 0 && height > 0 && pixels >= min_pixels
      [material, pixels]
    end.compact.sort_by { |material, pixels| [-pixels, material.name.to_s] }
    candidates = eligible.first(limit)

    FileUtils.mkdir_p(output_root)
    session = File.join(output_root, "probe-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}")
    Dir.mkdir(session)
    report = { schema: 'exact-texture-probe-v2', ready: false, status: 'running',
      capture_pixels: capture_pixels, eligible_texture_count: eligible.length,
      min_pixels: min_pixels, max_pixels: max_pixels,
      eligible_textures_not_sampled: eligible.length - candidates.length, oversized_jpeg_textures_skipped: skipped_large,
      script_sha256: Digest::SHA256.file(__FILE__).hexdigest,
      source_path: model.path, source_sha256: Digest::SHA256.file(model.path).hexdigest,
      source_bytes: File.size(model.path), ruby_version: RUBY_DESCRIPTION,
      sketchup_version: (Sketchup.version if defined?(Sketchup)), textures: [] }
    report_path = File.join(session, 'report.json')
    File.write(report_path, JSON.pretty_generate(report))
    candidates.each_with_index do |(material, _pixels), index|
      entry = { material: material.name.to_s, status: 'running' }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        path = File.join(session, "texture-#{index}.jpg")
        texture = material.texture
        raise 'Embedded JPEG extraction failed' unless texture.write(path, false) && File.file?(path)
        reference = texture.image_rep(true)
        uncolorized = texture.image_rep(false)
        candidate = loader.call(path)
        entry.merge!(status: 'measured', width: reference.width, height: reference.height,
          bytes: File.size(path), sha256: Digest::SHA256.file(path).hexdigest,
          pixel_identical: same_pixels?(reference, candidate),
          colorization_changes_pixels: !same_pixels?(reference, uncolorized),
          jpeg_matches_uncolorized: same_pixels?(uncolorized, candidate))
        if capture_pixels
          entry[:pixel_evidence] = {
            colorized: save_pixels(reference, session, "texture-#{index}.colorized.raw.gz"),
            uncolorized: save_pixels(uncolorized, session, "texture-#{index}.uncolorized.raw.gz"),
            jpeg_decoded: save_pixels(candidate, session, "texture-#{index}.jpeg-decoded.raw.gz")
          }
        end
      rescue StandardError => error
        entry.merge!(status: 'failed', error: "#{error.class}: #{error.message}")
      ensure
        entry[:elapsed_seconds] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        report[:textures] << entry
        File.write(report_path, JSON.pretty_generate(report))
      end
    end
    report[:status] = candidates.empty? ? 'no_eligible_jpeg' : 'probe_complete'
    File.write(report_path, JSON.pretty_generate(report))
    puts "Exact texture probe: #{report_path} (diagnostic only; ready=false)"
    session
  end
end
