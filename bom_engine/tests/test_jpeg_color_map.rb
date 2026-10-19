require 'minitest/autorun'
require 'digest'
require 'json'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require_relative '../bomc_validator'
require_relative '../bomc_jpeg_color_map' if File.file?(File.expand_path('../bomc_jpeg_color_map.rb', __dir__))

class JpegColorMapTest < Minitest::Test
  BASE = [10,20,30,255,40,50,60,255].pack('C*').freeze
  TARGET = [11,22,33,255,44,55,66,255].pack('C*').freeze
  JPEG = [255,216,255,192,0,17,8,0,1,0,2,3,1,17,0,2,17,0,3,17,0,255,218,0,12,3,1,0,2,0,3,0,0,63,0,1,255,217].pack('C*').freeze
  def codec
    assert defined?(BOMEngine::BOMCJpegColorMap), 'Exact color-map implementation missing'
    BOMEngine::BOMCJpegColorMap
  end
  def encode(**overrides, &block)
    codec.encode(**{jpeg: JPEG, base_rgba: BASE, target_rgba: TARGET, width: 2, height: 1}.merge(overrides), &block)
  end
  def test_exact_round_trip_and_independent_wire_layout
    bytes = encode
    assert_equal "BOMJCM\r\n".b + [1,0,0,1].pack('C*'), bytes.byteslice(0,12)
    assert_equal [2,1,2,JPEG.bytesize,0], bytes.byteslice(12,20).unpack('V5')
    assert_equal Digest::SHA256.digest(JPEG), bytes.byteslice(32,32)
    assert_equal [10,20,30,11,22,33,255,40,50,60,44,55,66,255].pack('C*'), bytes.byteslice(-14,14)
    assert_equal TARGET, codec.reconstruct(bytes, BASE)
  end
  def test_conflicting_color_mapping_uses_residual_instead_of_failing
    jpeg = JPEG.dup
    jpeg[7,4] = [1,2].pack('n2')
    base = BASE.byteslice(0,4) * 2
    bytes = encode(jpeg: jpeg, base_rgba: base, target_rgba: TARGET, width: 2, height: 1)
    assert_equal BOMEngine::BOMCJpegColorMap::XOR_RESIDUAL_DEFLATE, bytes.getbyte(10)
    assert_equal TARGET, codec.reconstruct(bytes, base)
  end
  def test_deflated_dictionary_wire_round_trip
    dictionary = [10,20,30,11,22,33,255,40,50,60,44,55,66,255].pack('C*')
    compressed = Zlib::Deflate.deflate(dictionary, Zlib::BEST_COMPRESSION)
    bytes = codec.send(
      :serialize,
      jpeg: JPEG, base_rgba: BASE, target_rgba: TARGET, width: 2, height: 1, count: 2,
      codec: BOMEngine::BOMCJpegColorMap::DICTIONARY_DEFLATE, correction: compressed
    )
    assert_equal BOMEngine::BOMCJpegColorMap::DICTIONARY_DEFLATE, bytes.getbyte(10)
    assert_equal compressed.bytesize, bytes.byteslice(28,4).unpack1('V')
    assert_equal TARGET, codec.reconstruct(bytes, BASE)
  end

  def test_conflicting_dictionary_falls_back_to_exact_xor_residual
    base = BASE.byteslice(0,4) * 2
    target = [11,22,33,255,44,55,66,255].pack('C*')
    jpeg = JPEG.dup
    jpeg[7,4] = [1,2].pack('n2')
    bytes = encode(jpeg: jpeg, base_rgba: base, target_rgba: target, width: 2, height: 1)
    assert_equal BOMEngine::BOMCJpegColorMap::XOR_RESIDUAL_DEFLATE, bytes.getbyte(10)
    assert_equal target, codec.reconstruct(bytes, base)
  end

  def test_repeated_colors_do_not_allocate_one_target_string_per_pixel
    tracked=Class.new(String) do
      attr_reader :pixel_slices
      def byteslice(offset,length)
        @pixel_slices=(@pixel_slices || 0)+1 if length==4
        super
      end
    end
    width,height=256,256
    jpeg=JPEG.dup;jpeg[7,4]=[height,width].pack('n2')
    base=BASE.byteslice(0,4)*(width*height)
    target=tracked.new(TARGET.byteslice(0,4)*(width*height))
    bytes=encode(jpeg:jpeg,base_rgba:base,target_rgba:target,width:width,height:height)
    assert_equal String.new(target),codec.reconstruct(bytes,base)
    assert_operator target.pixel_slices.to_i,:<=,1,'repeated colors must not create pixel-sized temporary strings'
  end
  def test_transparency_uses_another_lossless_codec
    rgba = TARGET.dup; rgba.setbyte(3,127)
    assert_nil encode(target_rgba: rgba)
  end
  def test_refuses_wrong_dimensions_and_frame_length
    assert_raises(ArgumentError) { encode(width: 3) }
    assert_raises(ArgumentError) { encode(base_rgba: BASE.byteslice(0,7)) }
    assert_raises(ArgumentError) { encode(width: 0) }
  end
  def test_high_color_count_uses_bounded_residual_instead_of_unbounded_dictionary
    count=1024*257
    pixels=+''.b
    count.times { |i| pixels << [i>>16,(i>>8)&255,i&255,255].pack('C*') }
    jpeg=JPEG.dup;jpeg[7,4]=[257,1024].pack('n2')
    bytes=encode(jpeg:jpeg,base_rgba:pixels,target_rgba:pixels,width:1024,height:257)
    assert_equal BOMEngine::BOMCJpegColorMap::XOR_RESIDUAL_DEFLATE, bytes.getbyte(10)
    assert_equal pixels, codec.reconstruct(bytes,pixels)
  end
  def test_modified_base_or_mapping_cannot_publish_pixels
    bytes = encode
    changed = BASE.dup; changed.setbyte(0,11)
    assert_raises(ArgumentError) { codec.reconstruct(bytes, changed) }
    bytes.setbyte(128+JPEG.bytesize+3,12)
    assert_raises(ArgumentError) { codec.reconstruct(bytes, BASE) }
  end
  def test_unknown_header_truncated_trailing_and_duplicate_keys_rejected
    original = encode
    mutations = [original.byteslice(0,original.bytesize-1),original+"\0"]
    [8,9,10,11,28].each { |offset| b=original.dup; b.setbyte(offset,9); mutations << b }
    duplicate=original.dup; duplicate[128+JPEG.bytesize+7,3]=[10,20,30].pack('C*');mutations << duplicate
    mutations.each { |bytes| assert_raises(ArgumentError) { codec.parse(bytes) } }
  end
  def test_jpeg_dimensions_and_metadata_checked_before_decode
    bytes=JPEG.dup; bytes.setbyte(10,3)
    assert_raises(ArgumentError) { encode(jpeg:bytes) }
    [0xe1,0xe2,0xee].each do |marker|
      bytes=JPEG.dup;bytes.setbyte(3,marker)
      assert_raises(ArgumentError) { encode(jpeg:bytes) }
    end
  end
  def test_cancellation_is_not_swallowed
    failure=Class.new(StandardError)
    assert_raises(failure) { encode { raise failure } }
  end
  def test_normalization_removes_metadata_without_touching_compressed_scan
    tagged = JPEG.byteslice(0,2) + [255,225,0,8].pack('C*') + "Exif\0\0" + JPEG.byteslice(2,JPEG.bytesize-2)
    assert_equal JPEG, codec.normalize_jpeg(tagged,2,1)
    assert_equal JPEG, codec.normalize_jpeg(JPEG,2,1)
    malformed=tagged.dup;malformed.setbyte(4,255)
    assert_raises(ArgumentError) { codec.normalize_jpeg(malformed,2,1) }
  end
  def test_container_uses_table_v2_and_standard_reader_accepts_jcm
    graph={materials:[{id:'m'}],definitions:[{id:'d',kind:'root',node_ids:[]}],nodes:[{id:'root',kind:'root',definition_id:'d',transform_id:0}],transforms:[BOMEngine::BOMC::ModelAdapter::IDENTITY],meshes:[],tags:[]}
    graph[:materials][0][:texture]={bytes:encode,filename:'sample.jcm',image_width_px:2,image_height_px:1}
    bytes=BOMEngine::BOMCWriter.pack(graph,profile: :exact)[:bytes]
    decoded=BOMEngine::BOMCDecoder.decode(bytes)
    assert_equal :jpeg_color_map, decoded[:textures][0][:media_type]
    assert_equal TARGET, codec.reconstruct(decoded[:textures][0][:bytes],BASE)
    assert_raises(RuntimeError) { BOMEngine::BOMCDecoder.decode(bytes,allow_jpeg_color_map:false) }
  end
  def test_writer_preserves_internally_compressed_jcm_payload
    width=100;height=10
    jpeg=JPEG.dup;jpeg[7,4]=[height,width].pack('n2')
    base=Array.new(width*height) { |index| [index >> 8,(index >> 4) & 255,index & 15,255] }.flatten.pack('C*')
    target=Array.new(width*height) { [200,100,50,255] }.flatten.pack('C*')
    texture=codec.encode(jpeg:jpeg,base_rgba:base,target_rgba:target,width:width,height:height)
    graph={materials:[{id:'m',texture:{bytes:texture,filename:'mapped.jcm',image_width_px:width,image_height_px:height}}],
      definitions:[{id:'d',kind:'root',node_ids:[]}],nodes:[{id:'root',kind:'root',definition_id:'d',transform_id:0}],
      transforms:[BOMEngine::BOMC::ModelAdapter::IDENTITY],meshes:[],tags:[]}

    packed=BOMEngine::BOMCWriter.pack(graph,profile: :exact)
    blob=packed.dig(:metrics,:sections,:textures)
    assert_includes [0,1],blob[:codec], 'container may keep or additionally deflate an already-compressed JCM payload'
    decoded=BOMEngine::BOMCDecoder.decode(packed[:bytes],allow_jpeg_color_map:true)
    assert_equal texture,decoded[:textures][0][:bytes], 'container decode retains exact JCM payload bytes'
    assert_equal target,codec.reconstruct(decoded[:textures][0][:bytes],base)
  end
  def test_exact_publication_requires_digest_bound_color_map_pixel_evidence
    texture=encode
    graph={materials:[{id:'m',texture:{bytes:texture,filename:'sample.jcm',image_width_px:2,image_height_px:1}}],definitions:[{id:'d',kind:'root',node_ids:[]}],nodes:[{id:'root',kind:'root',definition_id:'d',transform_id:0}],transforms:[BOMEngine::BOMC::ModelAdapter::IDENTITY],meshes:[],tags:[]}
    bytes=BOMEngine::BOMCWriter.pack(graph,profile: :exact)[:bytes]
    decoded=BOMEngine::BOMCDecoder.decode(bytes,allow_jpeg_color_map:true)
    assert_raises(BOMEngine::BOMCValidator::ProfileValidationError) { BOMEngine::BOMCValidator.validate_profile!(source:graph,decoded:decoded,profile: :exact) }
    evidence={policy_revision:'exact-jcm-1',selected: :jpeg_color_map_candidate,profile: :exact,alpha_preserved:true,
      selected_sha256:Digest::SHA256.hexdigest(texture),base_pixel_sha256:Digest::SHA256.hexdigest(BASE),output_pixel_sha256:Digest::SHA256.hexdigest(TARGET),normalized_jpeg_sha256:Digest::SHA256.hexdigest(JPEG),
      required_loader:'bomc-next-jcm-v1',quality:{compatible:true,mean_squared_error:0.0,max_channel_error:0,alpha_preserved:true}}
    BOMEngine::BOMCValidator.validate_profile!(source:graph,decoded:decoded,profile: :exact,texture_evidence:[evidence])
    [:selected_sha256,:base_pixel_sha256,:output_pixel_sha256,:normalized_jpeg_sha256].each do |field|
      assert_raises(BOMEngine::BOMCValidator::ProfileValidationError) { BOMEngine::BOMCValidator.validate_profile!(source:graph,decoded:decoded,profile: :exact,texture_evidence:[evidence.merge(field=>'0'*64)]) }
    end
  end
  def test_writer_enforces_consumer_aggregate_mapped_pixel_budget_after_texture_deduplication
    # Metadata-boundary fixtures only, not a claim of decoded image fidelity.
    payloads=5.times.map do |index|
      bytes=encode
      jpeg=JPEG.dup;jpeg[7,4]=[4000,8000].pack('n2');jpeg.setbyte(jpeg.bytesize-3,index+1)
      bytes[12,8]=[8000,4000].pack('V2')
      bytes[32,32]=Digest::SHA256.digest(jpeg);bytes[128,JPEG.bytesize]=jpeg
      bytes
    end
    graph={materials:[],definitions:[{id:'d',kind:'root',node_ids:[]}],nodes:[{id:'root',kind:'root',definition_id:'d',transform_id:0}],transforms:[BOMEngine::BOMC::ModelAdapter::IDENTITY],meshes:[],tags:[]}
    add=lambda { |bytes,index| {id:"m#{index}",texture:{bytes:bytes,filename:"#{index}.jcm",image_width_px:8000,image_height_px:4000}} }
    graph[:materials]=[payloads[0],payloads[1],payloads[2],payloads[3],payloads[0]].each_with_index.map(&add)
    assert BOMEngine::BOMCWriter.pack(graph,profile: :exact)[:bytes], 'four unique 32M textures exactly fit the 128M budget, duplicate is free'
    graph[:materials]=payloads.each_with_index.map(&add)
    error=assert_raises(RuntimeError) { BOMEngine::BOMCWriter.pack(graph,profile: :exact) }
    assert_match(/aggregate pixel budget/,error.message)
  end
end
