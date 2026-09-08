# frozen_string_literal: true

module BOMEngine
  module DecodeBudget
    class BudgetError < StandardError; end

    MAX_INPUT_BYTES = 80 * 1024 * 1024       # 80 MiB
    MAX_EXPANDED_BYTES = 120 * 1024 * 1024   # 120 MiB
    MAX_ALLOCATION_BYTES = 256 * 1024 * 1024 # 256 MiB
    MAX_SECTIONS = 64
    MAX_DEPTH = 64
    MAX_TEXTURE_PIXELS = 16_384 * 16_384

    module_function

    def checked_table_bytes(count, components, element_bytes, available_payload_bytes = nil, budget: MAX_ALLOCATION_BYTES, min_wire: element_bytes)
      cnt = Integer(count)
      comps = Integer(components)
      elem_bytes = Integer(element_bytes)

      raise BudgetError, "BOMC invalid: table count must be non-negative (got #{cnt})." if cnt < 0
      raise BudgetError, "BOMC invalid: components must be positive (got #{comps})." if comps <= 0
      raise BudgetError, "BOMC invalid: element_bytes must be positive (got #{elem_bytes})." if elem_bytes <= 0

      # Pre-multiplication budget check: count > floor(budget / (components * element_bytes))
      max_allowed_count = (budget.to_f / (comps * elem_bytes)).floor
      if cnt > max_allowed_count
        raise BudgetError, "BOMC invalid: table count #{cnt} exceeds allocation budget of #{budget} bytes (max allowed: #{max_allowed_count})."
      end

      # Wire availability check
      if available_payload_bytes
        avail = Integer(available_payload_bytes)
        raise BudgetError, "BOMC invalid: available_payload_bytes must be non-negative (got #{avail})." if avail < 0

        min_required = (cnt * comps * min_wire).ceil
        if avail < min_required
          raise BudgetError, "BOMC invalid: table count #{cnt} requires at least #{min_required} payload bytes, but only #{avail} bytes are available."
        end
      end

      cnt * comps * elem_bytes
    end
  end
end
