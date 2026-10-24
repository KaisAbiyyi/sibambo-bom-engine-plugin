# frozen_string_literal: true
require 'test/unit'
require_relative '../bomc_sketchup_colorize'
require_relative '../bomc_writer'
require_relative '../bomc_decoder'
require 'digest'

class TestBOMCSemanticColorize < Test::Unit::TestCase
  # Independently kept scalar implementation of the earlier, already-tested
  # published SketchUp HLS approximation. It deliberately retains the old
  # helper dispatch and float32 conversions so new fast-path code cannot be
  # its own oracle.
  module ReferenceColorize
    TOL = 1.0e-3
    module_function

    def less_than(a,b); (a-b)<=-TOL; end
    def greater_than(a,b); (a-b)>=TOL; end
    def equals(a,b); (a-b).abs<TOL; end
    def less_than_or_equal(a,b); less_than(a,b)||equals(a,b); end
    def clamp(v,min,max); [[v,min].max,max].min; end
    def double2byte(v); return 0 if v<=0.0; return 255 if v>=1.0; (v*255.0).to_i; end

    def rgb2hls(rb,gb,bb)
      r,g,b=[rb,gb,bb].map { |v| [v.to_f/255.0].pack('e').unpack1('e') }
      max=min=r; max=g if greater_than(g,max); max=b if greater_than(b,max)
      min=g if less_than(g,min); min=b if less_than(b,min)
      l=(max+min)/2.0; return [-1.0,l,0.0] if equals(min,max)
      s=less_than_or_equal(l,0.5) ? (max-min)/(max+min) : (max-min)/(2.0-max-min)
      rc=(max-r)/(max-min); gc=(max-g)/(max-min); bc=(max-b)/(max-min)
      h=equals(r,max) ? bc-gc : equals(g,max) ? 2.0+rc-bc : 4.0+gc-rc
      h*=60.0; h+=360.0 if less_than(h,0.0); [h,l,s]
    end

    def calc(n1,n2,h)
      h-=360.0 if greater_than(h,360.0); h+=360.0 if less_than(h,0.0)
      return n1+(n2-n1)*h/60.0 if less_than(h,60.0)
      return n2 if less_than(h,180.0)
      return n1+(n2-n1)*(240.0-h)/60.0 if less_than(h,240.0)
      n1
    end

    def hls2rgb(h,l,s)
      m2=less_than(l,0.5) ? l*(1.0+s) : l+s-(l*s); m1=2.0*l-m2
      [calc(m1,m2,h+120.0),calc(m1,m2,h),calc(m1,m2,h-120.0)].map { |v| double2byte(v) }
    end

    def transform(r,g,b,h_delta,l_delta,s_delta,shift)
      h,l,s=rgb2hls(r,g,b)
      h=shift ? h+h_delta : h_delta
      h+=360.0 while less_than(h,0.0); h-=360.0 while greater_than(h,360.0)
      s=clamp(s+s_delta,0.0,1.0); l=clamp(l+l_delta,0.01,1.0)
      return [double2byte(l)]*3 if equals(s,0.0)
      hls2rgb(h,l,s)
    end
  end

  def test_fast_hls_matches_prior_scalar_math_for_random_and_boundary_rgb
    current=BOMEngine::BOMCSketchupColorize
    random=Random.new(20261023)
    edge=[0,1,2,63,64,65,126,127,128,129,190,191,192,253,254,255]
    rgb_samples=edge.product(edge,edge)
    8_192.times { rgb_samples << [random.rand(256),random.rand(256),random.rand(256)] }
    adjustments=[
      [92.58741048890613,0.13725490868091583,-0.11229892646129502,true],
      [0.0,0.0,0.0,true],
      [180.0,-0.4,0.4,true],
      [359.999,-0.01,-0.999,false],
      [-30.0,0.5,0.003,false]
    ]
    adjustments.each do |h,l,s,shift|
      rgb_samples.each do |r,g,b|
        expected=ReferenceColorize.transform(r,g,b,h,l,s,shift)
        assert_equal expected,current.colorize_pixel(r,g,b,h,l,s,shift),
          "HLS byte identity for RGB=#{[r,g,b].inspect}, deltas=#{[h,l,s,shift].inspect}"
      end
    end
  end

  def test_float32_channel_table_matches_original_conversion_for_all_256_bytes
    table = BOMEngine::BOMCSketchupColorize::CHANNEL_F32
    assert_equal 256, table.size
    assert_equal true, table.frozen?
    256.times do |channel|
      original_float32 = [channel.to_f / 255.0].pack('e').unpack1('e')
      assert_equal original_float32, table[channel], "float32 channel conversion #{channel}"
    end
  end

  def test_matches_sketchup_reference_cpp_vector
    rgb = BOMEngine::BOMCSketchupColorize.colorize_pixel(
      115, 137, 98,
      92.58741048890613,
      0.13725490868091583,
      -0.11229892646129502,
      true
    )
    assert_equal [147, 156, 158], rgb
  end

  def test_semantic_verification_can_decline_an_over_budget_proof
    frame = Struct.new(:width, :height, :bits_per_pixel, :row_padding, :data).new(
      1, 1, 32, 0, "\x80\x80\x80\xff".b
    )
    result = BOMEngine::BOMCSketchupColorize.verify(
      uncolorized: frame, colorized: frame, mode: :shift,
      deltas: { h: 0, l: 0, s: 0 }, max_seconds: 0
    )
    assert_equal false, result[:passed]
    assert_equal :time_budget_exceeded, result[:reason]
  end

  def test_large_rgb24_semantic_proof_has_sub_32k_cancel_checkpoint
    colorize = BOMEngine::BOMCSketchupColorize
    r,g,b = 115,137,98
    rr,rg,rb = colorize.colorize_pixel(r,g,b,0,0,0,true)
    source_pixel = (Gem.win_platform? ? [b,g,r] : [r,g,b]).pack('C*')
    output_pixel = (Gem.win_platform? ? [rb,rg,rr,255] : [rr,rg,rb,255]).pack('C*')
    frame = Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data)
    source = frame.new(1,1_000_000,24,0,source_pixel*1_000_000)
    target = frame.new(1,1_000_000,32,0,output_pixel*1_000_000)
    seen = []
    assert_raise(Interrupt) do
      colorize.verify(uncolorized: source, colorized: target,
        mode: :shift, deltas: {h:0,l:0,s:0}, max_seconds:30,
        checkpoint: ->(done,_total) { seen << done; raise Interrupt })
    end
    assert_equal [1_024], seen, 'large image exits at the first bounded checkpoint without accepting partial pixels'
  end

  def test_multirow_semantic_proof_has_byte_exact_rgba_alpha_and_padding
    colorize = BOMEngine::BOMCSketchupColorize
    pixels = [[115,137,98,25], [115,137,98,255], [0,0,0,0],
              [255,255,255,127], [24,32,48,255], [115,137,98,55]]
    deltas = {h: 92.58741048890613, l: 0.13725490868091583, s: -0.11229892646129502}
    source_rgba = pixels.map { |p| p.pack('C4') }.join.b
    expected_rgba = pixels.map do |r,g,b,a|
      (colorize.colorize_pixel(r,g,b,deltas[:h],deltas[:l],deltas[:s],true) + [a]).pack('C4')
    end.join.b
    make_rep = ->(rgba) do
      rows = rgba.bytes.each_slice(12).map do |row|
        bytes = row.each_slice(4).flat_map { |r,g,b,a| Gem.win_platform? ? [b,g,r,a] : [r,g,b,a] }
        bytes.pack('C*') + "\0\0".b
      end
      Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data).new(3,2,32,2,rows.join.b)
    end
    source = make_rep.call(source_rgba)
    target = make_rep.call(expected_rgba)
    proof = colorize.verify(uncolorized: source, colorized: target, mode: :shift,
      deltas: deltas, max_seconds: 30)
    assert_equal true, proof[:passed]
    assert_equal Digest::SHA256.hexdigest(source_rgba), proof[:base_pixel_sha256]
    assert_equal Digest::SHA256.hexdigest(expected_rgba), proof[:output_pixel_sha256]
    target.data.setbyte(Gem.win_platform? ? 3 : 3, 128)
    mismatch = colorize.verify(uncolorized: source, colorized: target, mode: :shift,
      deltas: deltas, max_seconds: 30)
    assert_equal :pixel_mismatch, mismatch[:reason]
  end

  def test_rgba32_accelerated_proof_matches_conservative_rgb24_proof
    colorize = BOMEngine::BOMCSketchupColorize
    deltas = {h: 92.58741048890613, l: 0.13725490868091583, s: -0.11229892646129502}
    rgb = [[115,137,98], [0,0,0], [24,32,48], [255,255,255], [10,90,222]]
    # The 24-bit conservative path is an independent transform oracle;
    # opaque alpha makes normalized SHA-256 comparable across both layouts.
    rows = 5.times.map do |y|
      9.times.map do |x|
        r,g,b = rgb[(x*3+y)%rgb.length]
        a = 255
        [[r,g,b,a], colorize.colorize_pixel(r,g,b,*deltas.values,true)+[a]]
      end
    end
    make = lambda do |bit_depth,pick|
      channels = bit_depth/8
      row_padding = channels == 4 ? 5 : 3
      data = rows.map do |row|
        row.map do |tuple|
          rgba = tuple[pick]
          pixel = channels == 4 ? rgba : rgba[0,3]
          (Gem.win_platform? ? pixel[0,3].reverse + Array(pixel[3]) : pixel).pack('C*')
        end.join.b + ('x'*row_padding)
      end.join.b
      Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data).new(9,5,bit_depth,row_padding,data)
    end
    accelerated = colorize.verify(uncolorized: make.call(32,0),colorized: make.call(32,1),
      mode: :shift,deltas: deltas,max_seconds: 30)
    conservative = colorize.verify(uncolorized: make.call(24,0),colorized: make.call(24,1),
      mode: :shift,deltas: deltas,max_seconds: 30)
    assert_equal true,accelerated[:passed]
    assert_equal conservative,accelerated
  end

  def test_native_jpeg_rgb24_to_display_rgba32_matches_independent_rgb24_oracle
    colorize=BOMEngine::BOMCSketchupColorize
    deltas={h:-1.111102348365847,l:-0.17647060006856918,s:-0.05208786249966896}
    random=Random.new(20261023)
    pixels=Array.new(35) { [random.rand(256),random.rand(256),random.rand(256)] }
    make_frame=lambda do |depth,values,padding|
      rows=values.each_slice(7).map do |row|
        row.map { |rgba| (Gem.win_platform? ? rgba[0,3].reverse+rgba[3..-1] : rgba).pack('C*') }.join.b + ('x'*padding)
      end
      Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data).new(7,5,depth,padding,rows.join.b)
    end
    colorized=pixels.map do |r,g,b|
      colorize.colorize_pixel(r,g,b,*deltas.values,true)
    end
    source24=make_frame.call(24,pixels,3)
    expected24=make_frame.call(24,colorized,2)
    actual32=make_frame.call(32,colorized.map { |p| p+[255] },5)
    expected=colorize.verify(uncolorized:source24,colorized:expected24,
      mode: :shift,deltas:deltas,max_seconds:30)
    seen=[]
    actual=colorize.verify(uncolorized:source24,colorized:actual32,
      mode: :shift,deltas:deltas,max_seconds:30,
      checkpoint:->(done,total){seen << [done,total]})
    assert_equal true,expected[:passed]
    assert_equal expected,actual
    assert_equal [],seen

    # A fully opaque JPEG source cannot silently grow transparency in the
    # SketchUp display, even if the three color channels remain unchanged.
    actual32.data.setbyte(3,0)
    mismatch=colorize.verify(uncolorized:source24,colorized:actual32,
      mode: :shift,deltas:deltas,max_seconds:30)
    assert_equal false,mismatch[:passed]
    assert_equal :pixel_mismatch,mismatch[:reason]
    assert_equal 0,mismatch[:processed]
  end

  def test_native_jpeg_mixed_fast_path_preserves_checkpoint_boundary_and_late_mismatch
    colorize=BOMEngine::BOMCSketchupColorize
    red,green,blue=16,96,212
    rr,rg,rb=colorize.colorize_pixel(red,green,blue,0.0,0.0,0.0,true)
    native_source=(Gem.win_platform? ? [blue,green,red] : [red,green,blue]).pack('C3')
    native_target=(Gem.win_platform? ? [rb,rg,rr,255] : [rr,rg,rb,255]).pack('C4')
    width=1; height=32_769
    frame=Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data)
    source=frame.new(width,height,24,0,native_source*height)
    target=frame.new(width,height,32,0,native_target*height)
    checkpoints=[]
    deltas={h:0.0,l:0.0,s:0.0}
    result=colorize.verify(uncolorized:source,colorized:target,mode: :shift,
      deltas:deltas,max_seconds:30,
      checkpoint:->(done,total){checkpoints << [done,total]})
    assert_equal true,result[:passed]
    assert_equal [[32_768,32_769]],checkpoints
    target.data.setbyte(32_768*4+3,0)
    failed=colorize.verify(uncolorized:source,colorized:target,mode: :shift,
      deltas:deltas,max_seconds:30)
    assert_equal :pixel_mismatch,failed[:reason]
    assert_equal 32_768,failed[:processed]
  end

  def test_material_v2_round_trips_parametric_colorization
    graph = {
      materials: [{
        id: 'm', name: 'm', display_name: 'm',
        color: { r: 255, g: 255, b: 255, a: 255 }, opacity: 1.0,
        material_type: 2, semantic_colorize_active: true, colorize_type: 'shift',
        colorize_deltas: { h: 92.5, l: 0.1, s: -0.2 },
        colorize_output_sha256: 'ab' * 32
      }],
      definitions: [{ id: 'd', kind: 'root', node_ids: [] }],
      nodes: [{ id: 'root', kind: 'root', definition_id: 'd', transform_id: 0 }],
      transforms: [BOMEngine::BOMC::ModelAdapter::IDENTITY],
      meshes: [], tags: []
    }
    packed = BOMEngine::BOMCWriter.pack(graph, profile: :exact)
    material = BOMEngine::BOMCDecoder.decode(packed[:bytes])[:materials][0]

    assert_equal 2, material[:material_type]
    assert_equal true, material[:semantic_colorize_active]
    assert_equal 'shift', material[:colorize_type]
    assert_equal({ h: 92.5, l: 0.1, s: -0.2 }, material[:colorize_deltas])
    assert_equal 'ab' * 32, material[:colorize_output_sha256]
  end
end
