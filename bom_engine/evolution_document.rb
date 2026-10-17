# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require_relative 'performance_trace'

module BOMEngine
  module EvolutionDocument
    CONTRACT = 'sibambo-evolution-fidelity-v1'.freeze
    ASSET_PREFIX = 'assets/tex-'.freeze
    STRIPPED_KEYS = %w[_entity callback checkpoint temp_path temporary_path texture_directory].freeze
    MIME_BY_EXTENSION = {
      '.png' => 'image/png',
      '.jpg' => 'image/jpeg',
      '.jpeg' => 'image/jpeg',
      '.webp' => 'image/webp'
    }.freeze

    module_function

    def prepare(graph, engine:, profile:, source_tree_sha256:, historical_baseline_sha:)
      PerformanceTrace.stage(:graph_detach) do
        normalized_profile = normalize_profile(profile)
        normalized_engine = normalize_engine(engine)
        assets = {}
        assert_acyclic!(graph)
        portable_graph = deep_portable(graph, assets: assets, path: [])
        portable_graph.delete('source_info') if portable_graph.is_a?(Hash)
        if portable_graph['source'].is_a?(Hash)
          portable_graph['source'].delete('file_path')
        end
        portable_graph['evolution'] = {
          'contract' => CONTRACT,
          'engine' => normalized_engine,
          'profile' => normalized_profile,
          'source_tree_sha256' => validate_hash(source_tree_sha256, 'source tree SHA-256'),
          'historical_baseline_sha' => validate_commit(historical_baseline_sha)
        }

        document = {
          'contract' => CONTRACT,
          'engine' => normalized_engine,
          'profile' => normalized_profile,
          'graph' => portable_graph,
          'assets' => assets.values.sort_by { |asset| asset.fetch('id') }
        }
        validate!(document)
        document
      end
    end

    def validate!(document)
      raise ArgumentError, 'Evolution document must be a Hash' unless document.is_a?(Hash)
      raise ArgumentError, 'Wrong Evolution contract' unless document['contract'] == CONTRACT
      normalize_engine(document.fetch('engine'))
      normalize_profile(document.fetch('profile'))
      graph = document.fetch('graph')
      raise ArgumentError, 'Evolution graph must be a Hash' unless graph.is_a?(Hash)

      asset_ids = {}
      Array(document['assets']).each do |asset|
        id = asset.fetch('id')
        raise ArgumentError, "Duplicate Evolution asset #{id}" if asset_ids[id]
        asset_ids[id] = true
        bytes = asset.fetch('bytes')
        raise ArgumentError, "Evolution asset #{id} has no bytes" unless bytes.is_a?(String)
        raise ArgumentError, "Evolution asset #{id} byte length mismatch" unless bytes.bytesize == asset.fetch('byte_length')
        raise ArgumentError, "Evolution asset #{id} SHA-256 mismatch" unless Digest::SHA256.hexdigest(bytes) == asset.fetch('sha256')
      end

      walk = lambda do |value, path|
        case value
        when Hash
          value.each do |key, child|
            raise ArgumentError, "Evolution document contains stripped key #{key} at #{path.join('.')}" if STRIPPED_KEYS.include?(key.to_s)
            if key.to_s == 'asset_id' && !asset_ids[child]
              raise ArgumentError, "Dangling Evolution asset reference #{child.inspect}"
            end
            walk.call(child, path + [key.to_s])
          end
        when Array
          value.each_with_index { |child, index| walk.call(child, path + [index.to_s]) }
        when Float
          raise ArgumentError, "Non-finite Evolution numeric value at #{path.join('.')}" unless value.finite?
        when Integer, String, TrueClass, FalseClass, NilClass
          nil
        else
          raise ArgumentError, "Unsupported Evolution value #{value.class} at #{path.join('.')}"
        end
      end
      walk.call(graph, ['graph'])
      true
    end

    def json_asset_table(document)
      Array(document.fetch('assets')).map do |asset|
        asset.reject { |key, _| key == 'bytes' }.merge('data_base64' => Base64.strict_encode64(asset.fetch('bytes')))
      end
    end

    def graph_with_json_assets(document)
      deep_copy(document.fetch('graph')).merge('assets' => json_asset_table(document))
    end

    def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), result| result[key] = deep_copy(child) }
      when Array
        value.map { |child| deep_copy(child) }
      when String
        value.dup
      else
        value
      end
    end

    def assert_acyclic!(value, active = {}, path = [])
      return unless value.is_a?(Hash) || value.is_a?(Array)
      object_id = value.object_id
      raise ArgumentError, "Cycle detected in Evolution capture at #{path.join('.')}" if active[object_id]
      active[object_id] = true
      if value.is_a?(Hash)
        value.each { |key, child| assert_acyclic!(child, active, path + [key.to_s]) }
      else
        value.each_with_index { |child, index| assert_acyclic!(child, active, path + [index.to_s]) }
      end
      active.delete(object_id)
    end
    private_class_method :assert_acyclic!

    def deep_portable(value, assets:, path:)
      case value
      when Hash
        normalize_evidence_hash(value, assets: assets, path: path)
      when Array
        value.each_with_index.map { |child, index| deep_portable(child, assets: assets, path: path + [index.to_s]) }
      when Symbol
        value.to_s
      when Float
        raise ArgumentError, "Non-finite Evolution numeric value at #{path.join('.')}" unless value.finite?
        value
      when Integer, String, TrueClass, FalseClass, NilClass
        value
      else
        raise ArgumentError, "Host/runtime object #{value.class} remained at #{path.join('.')}"
      end
    end
    private_class_method :deep_portable

    def normalize_evidence_hash(value, assets:, path:)
      result = {}
      value.each do |raw_key, child|
        key = raw_key.to_s
        next if STRIPPED_KEYS.include?(key)

        if key == 'texture' && child.is_a?(Hash)
          result[key] = portable_texture(child, assets: assets, path: path + [key])
          next
        end

        if key == 'psnr_db' && child.is_a?(Float) && child.infinite?
          if lossless_evidence?(value)
            result[key] = nil
            result['pixel_lossless'] = true
            next
          end
          raise ArgumentError, "Non-finite PSNR without lossless evidence at #{path.join('.')}"
        end
        result[key] = deep_portable(child, assets: assets, path: path + [key])
      end
      result
    end
    private_class_method :normalize_evidence_hash

    def portable_texture(texture, assets:, path:)
      result = {}
      source_path = texture[:source_path] || texture['source_path']
      texture.each do |raw_key, child|
        key = raw_key.to_s
        next if key == 'source_path'
        result[key] = deep_portable(child, assets: assets, path: path + [key])
      end
      return result if source_path.to_s.empty?
      raise ArgumentError, "Portable texture does not exist: #{source_path}" unless File.file?(source_path)

      bytes = File.binread(source_path)
      sha = Digest::SHA256.hexdigest(bytes)
      extension = normalized_extension(source_path)
      id = "#{ASSET_PREFIX}#{sha}#{extension}"
      staging = texture[:staging_evidence] || texture['staging_evidence'] || {}
      pixel_sha = staging[:reference_pixel_sha256] || staging['reference_pixel_sha256'] ||
        staging[:output_pixel_sha256] || staging['output_pixel_sha256']
      asset = {
        'id' => id,
        'path' => id,
        'media_type' => MIME_BY_EXTENSION.fetch(extension),
        'byte_length' => bytes.bytesize,
        'sha256' => sha,
        'bytes' => bytes
      }
      if pixel_sha
        raise ArgumentError, "Invalid displayed-pixel SHA-256 for #{id}" unless pixel_sha.to_s.match?(/\A[0-9a-f]{64}\z/i)
        asset['displayed_rgba_sha256'] = pixel_sha.to_s.downcase
      end
      assets[id] ||= asset
      result['asset_id'] = id
      result['filename'] = File.basename(id)
      result
    end
    private_class_method :portable_texture

    def normalized_extension(path)
      extension = File.extname(path.to_s).downcase
      extension = '.jpg' if extension == '.jpeg'
      raise ArgumentError, "Unsupported portable texture extension: #{extension}" unless MIME_BY_EXTENSION.key?(extension)
      extension
    end
    private_class_method :normalized_extension

    def lossless_evidence?(hash)
      mse = hash[:mean_squared_error] || hash['mean_squared_error']
      max_error = hash[:max_channel_error] || hash['max_channel_error']
      alpha = hash.key?(:alpha_preserved) ? hash[:alpha_preserved] : hash['alpha_preserved']
      mse.to_f.zero? && max_error.to_i.zero? && alpha == true
    end
    private_class_method :lossless_evidence?

    def normalize_profile(value)
      profile = value.to_s.downcase
      raise ArgumentError, "Unsupported Evolution profile: #{value}" unless %w[visual research exact].include?(profile)
      profile
    end
    private_class_method :normalize_profile

    def normalize_engine(value)
      engine = value.to_s.downcase
      raise ArgumentError, "Unsupported Evolution engine: #{value}" unless %w[e1 e2 e3].include?(engine)
      engine
    end
    private_class_method :normalize_engine

    def validate_hash(value, label)
      text = value.to_s.downcase
      raise ArgumentError, "Invalid #{label}" unless text.match?(/\A[0-9a-f]{64}\z/)
      text
    end
    private_class_method :validate_hash

    def validate_commit(value)
      text = value.to_s.downcase
      raise ArgumentError, 'Invalid historical baseline SHA' unless text.match?(/\A[0-9a-f]{40}\z/)
      text
    end
    private_class_method :validate_commit
  end
end
