# frozen_string_literal: true
# BOMC Texture Quality Policy and Semantic Thresholds (Batch 7)

require_relative 'bomc_geometry_policy'

module BOMEngine
  module BOMCTexturePolicy
    # Quality Gates (PSNR in dB)
    RESEARCH_OPAQUE_MIN_PSNR = 42.0
    RESEARCH_NATIVE_JPEG_MIN_PSNR = 38.0

    VISUAL_CLASS_A_MIN_PSNR = 40.0
    VISUAL_CLASS_B_MIN_PSNR = 38.0
    VISUAL_CLASS_C_MIN_PSNR = 35.0
    VISUAL_NATIVE_JPEG_MIN_PSNR = 35.0

    module_function

    def min_psnr(profile:, semantic_class: :class_b, native_jpeg: false)
      prof = profile.to_s.downcase.to_sym
      klass = semantic_class.to_s.downcase.to_sym
      klass = :class_b unless [:class_a, :class_b, :class_c].include?(klass)

      case prof
      when :exact
        Float::INFINITY
      when :research
        native_jpeg ? RESEARCH_NATIVE_JPEG_MIN_PSNR : RESEARCH_OPAQUE_MIN_PSNR
      when :visual, :production, :debug
        return VISUAL_NATIVE_JPEG_MIN_PSNR if native_jpeg
        case klass
        when :class_a then VISUAL_CLASS_A_MIN_PSNR
        when :class_b then VISUAL_CLASS_B_MIN_PSNR
        when :class_c then VISUAL_CLASS_C_MIN_PSNR
        else VISUAL_CLASS_B_MIN_PSNR
        end
      else
        VISUAL_CLASS_B_MIN_PSNR
      end
    end

    def strictest_semantic_class(classes)
      list = Array(classes).compact.map { |c| c.to_s.downcase.to_sym }
      return :class_b if list.empty?
      if list.include?(:class_a)
        :class_a
      elsif list.include?(:class_b)
        :class_b
      else
        :class_c
      end
    end
  end
end
