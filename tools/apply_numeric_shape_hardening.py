from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly 1 match, found {count}")
    return text.replace(old, new, 1)


adapter_path = Path('bom_engine/bomc_model_adapter.rb')
adapter = adapter_path.read_text(encoding='utf-8')

adapter = replace_once(
    adapter,
    "require 'digest'\nrequire_relative 'scene_clip_program'",
    "require 'digest'\nrequire_relative 'numeric_shape'\nrequire_relative 'scene_clip_program'",
    'adapter require numeric_shape',
)
adapter = replace_once(
    adapter,
    "positions = Array(mesh[:positions_m]).map(&:to_f)",
    "positions = NumericShape.flat_xyz(mesh[:positions_m], path: \"meshes[#{mesh_index_value}].positions_m\")",
    'canonical positions normalization',
)
adapter = replace_once(
    adapter,
    "canonical_face(face, positions, material_index, tag_index, materials)",
    "canonical_face(face, positions, material_index, tag_index, materials, path: \"meshes[#{mesh_index_value}].faces[#{face_index}]\")",
    'canonical face contextual path',
)
adapter = replace_once(
    adapter,
    "raw_scenes.map do |scene|",
    "raw_scenes.each_with_index.map do |scene, scene_index|",
    'scene index context',
)
adapter = replace_once(
    adapter,
    "eye_m: Array(camera[:eye_m]).map(&:to_f),\n              target_m: Array(camera[:target_m]).map(&:to_f),\n              up: Array(camera[:up]).map(&:to_f),",
    "eye_m: NumericShape.vec3(camera[:eye_m], path: \"scenes[#{scene_index}].camera.eye_m\"),\n              target_m: NumericShape.vec3(camera[:target_m], path: \"scenes[#{scene_index}].camera.target_m\"),\n              up: NumericShape.vec3(camera[:up], path: \"scenes[#{scene_index}].camera.up\"),",
    'scene camera vectors',
)
adapter = replace_once(
    adapter,
    "def canonical_face(face, positions, material_index, tag_index, materials)",
    "def canonical_face(face, positions, material_index, tag_index, materials, path: 'face')",
    'canonical face signature',
)
adapter = replace_once(
    adapter,
    "normal: Array(face[:normal]).empty? ? face_normal(positions, outer) : Array(face[:normal]).map(&:to_f),\n          area_m2: face[:area_m2].to_f,",
    "normal: Array(face[:normal]).empty? ? face_normal(positions, outer) : NumericShape.vec3(face[:normal], path: \"#{path}.normal\"),\n          area_m2: NumericShape.scalar(face[:area_m2], path: \"#{path}.area_m2\"),",
    'face normal and area',
)
adapter = replace_once(
    adapter,
    "uv: normalize_uv_for_materials(face[:uv], front_material, back_material, materials)",
    "uv: normalize_uv_for_materials(face[:uv], front_material, back_material, materials, path: \"#{path}.uv\")",
    'face uv path',
)
adapter = replace_once(
    adapter,
    "def normalize_uv_for_materials(uv, front_material, back_material, materials)\n        normalized = normalize_uv(uv)",
    "def normalize_uv_for_materials(uv, front_material, back_material, materials, path: 'uv')\n        normalized = normalize_uv(uv, path: path)",
    'uv material normalization signature',
)
adapter = replace_once(
    adapter,
    "def normalize_uv(uv)\n        return nil unless uv.is_a?(Hash)\n\n        result = {}\n        [:front_outer, :back_outer].each do |key|\n          result[key] = Array(uv[key]).map { |pair| Array(pair).map(&:to_f) }\n        end\n        [:front_holes, :back_holes].each do |key|\n          result[key] = Array(uv[key]).map { |loop| Array(loop).map { |pair| Array(pair).map(&:to_f) } }\n        end\n        result\n      end",
    "def normalize_uv(uv, path: 'uv')\n        return nil unless uv.is_a?(Hash)\n\n        result = {}\n        [:front_outer, :back_outer].each do |key|\n          result[key] = Array(uv[key]).each_with_index.map do |pair, pair_index|\n            NumericShape.vec2(pair, path: \"#{path}.#{key}[#{pair_index}]\")\n          end\n        end\n        [:front_holes, :back_holes].each do |key|\n          result[key] = Array(uv[key]).each_with_index.map do |loop, loop_index|\n            Array(loop).each_with_index.map do |pair, pair_index|\n              NumericShape.vec2(pair, path: \"#{path}.#{key}[#{loop_index}][#{pair_index}]\")\n            end\n          end\n        end\n        result\n      end",
    'typed uv normalization',
)
adapter = replace_once(
    adapter,
    "Array(matrix).map(&:to_f)",
    "NumericShape.flat_numeric(Array(matrix), path: \"transforms[#{index}]\", expected_length: 16)",
    'nested transform normalization',
)
adapter = replace_once(
    adapter,
    "values.each_slice(16).map { |matrix| matrix.map(&:to_f) }",
    "values.each_slice(16).with_index.map { |matrix, index| NumericShape.flat_numeric(matrix, path: \"transforms[#{index}]\", expected_length: 16) }",
    'flat transform normalization',
)
adapter = replace_once(
    adapter,
    "kind: 'image', position: Array(image[:position]).map(&:to_f),\n            width_m: image[:width_m].to_f, height_m: image[:height_m].to_f,",
    "kind: 'image', position: NumericShape.vec3(image[:position], path: \"instances.fallback.image.position\"),\n            width_m: NumericShape.scalar(image[:width_m], path: \"instances.fallback.image.width_m\"), height_m: NumericShape.scalar(image[:height_m], path: \"instances.fallback.image.height_m\"),",
    'image fallback numeric normalization',
)
adapter = replace_once(
    adapter,
    "minimum = Array(quantization[:minimum_m]).map(&:to_f)\n        scale = Array(quantization[:scale_m]).map(&:to_f)",
    "minimum = NumericShape.vec3(quantization[:minimum_m], path: 'model_eval.quantization.minimum_m')\n        scale = NumericShape.vec3(quantization[:scale_m], path: 'model_eval.quantization.scale_m')",
    'model eval quantization vectors',
)

adapter_path.write_text(adapter, encoding='utf-8')

clip_path = Path('bom_engine/scene_clip_program.rb')
clip = clip_path.read_text(encoding='utf-8')
clip = replace_once(
    clip,
    "require_relative 'bomc_format'",
    "require_relative 'bomc_format'\nrequire_relative 'numeric_shape'",
    'clip require numeric_shape',
)
clip = replace_once(
    clip,
    "orig = Array(origin_m).map(&:to_f)\n      norm = Array(normal).map(&:to_f)",
    "orig = NumericShape.vec3(origin_m, path: 'clip_plane.origin_m')\n      norm = NumericShape.vec3(normal, path: 'clip_plane.normal')",
    'clip create_plane vectors',
)
clip = replace_once(
    clip,
    "orig = Array(p[:origin_m]).map(&:to_f)\n        norm = Array(p[:normal]).map(&:to_f)",
    "orig = NumericShape.vec3(p[:origin_m], path: \"clip_planes[#{p[:stable_id]}].origin_m\")\n        norm = NumericShape.vec3(p[:normal], path: \"clip_planes[#{p[:stable_id]}].normal\")",
    'clip build_section vectors',
)
clip_path.write_text(clip, encoding='utf-8')

print('numeric shape hardening patch applied')
