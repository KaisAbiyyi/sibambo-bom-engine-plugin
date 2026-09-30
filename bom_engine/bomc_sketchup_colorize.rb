# frozen_string_literal: true
require 'digest'

module BOMEngine
  # Byte-exact port of SketchUp's published colorization algorithm.
  module BOMCSketchupColorize
    EQUAL_TOL = 1.0e-3
    module_function

    def verify(uncolorized:, colorized:, mode:, deltas:, checkpoint: nil)
      source=frame(uncolorized); target=frame(colorized)
      return {passed:false,reason: :dimension_mismatch} unless source[:width]==target[:width] && source[:height]==target[:height]
      h,l,s=normalize_deltas(deltas); shift=mode.to_s=='shift'
      digest=Digest::SHA256.new; base_digest=Digest::SHA256.new
      processed=0
      source[:height].times do |row|
        so=row*source[:stride]; to=row*target[:stride]
        source[:width].times do
          sr,sg,sb,sa=logical_rgba(source,so); tr,tg,tb,ta=logical_rgba(target,to)
          rr,rg,rb=colorize_pixel(sr,sg,sb,h,l,s,shift)
          return {passed:false,reason: :pixel_mismatch,processed:processed} unless [rr,rg,rb,sa]==[tr,tg,tb,ta]
          base_digest.update([sr,sg,sb,sa].pack('C4')); digest.update([rr,rg,rb,sa].pack('C4'))
          so+=source[:channels]; to+=target[:channels]; processed+=1
          checkpoint.call(processed,source[:width]*source[:height]) if checkpoint && (processed%32_768).zero?
        end
      end
      {passed:true,width:source[:width],height:source[:height],pixels:processed,
       base_pixel_sha256:base_digest.hexdigest,output_pixel_sha256:digest.hexdigest}
    end

    def colorize_pixel(r,g,b,h_delta,l_delta,s_delta,shift)
      h,l,s=rgb2hls(r,g,b)
      h=shift ? h+h_delta : h_delta
      h+=360.0 while less_than(h,0.0); h-=360.0 while greater_than(h,360.0)
      s=clamp(s+s_delta,0.0,1.0); l=clamp(l+l_delta,0.01,1.0)
      return [double2byte(l)]*3 if equals(s,0.0)
      hls2rgb(h,l,s)
    end

    def frame(image)
      width=Integer(image.width); height=Integer(image.height); bits=Integer(image.bits_per_pixel)
      padding=Integer(image.row_padding); data=image.data; channels=bits/8; stride=width*channels+padding
      raise ArgumentError,'Invalid SketchUp image frame' unless width>0 && height>0 && [3,4].include?(channels) &&
        padding>=0 && data.is_a?(String) && data.bytesize>=stride*height
      {width:width,height:height,channels:channels,stride:stride,data:data}
    end

    def logical_rgba(f,o)
      if Gem.win_platform?
        [f[:data].getbyte(o+2),f[:data].getbyte(o+1),f[:data].getbyte(o),f[:channels]==4 ? f[:data].getbyte(o+3) : 255]
      else
        [f[:data].getbyte(o),f[:data].getbyte(o+1),f[:data].getbyte(o+2),f[:channels]==4 ? f[:data].getbyte(o+3) : 255]
      end
    end
    private_class_method :logical_rgba

    def normalize_deltas(v)
      return [v[:h]||v['h'],v[:l]||v['l'],v[:s]||v['s']].map(&:to_f) if v.is_a?(Hash)
      Array(v).first(3).map(&:to_f)
    end
    private_class_method :normalize_deltas

    def rgb2hls(rb,gb,bb)
      r,g,b=[rb,gb,bb].map{|v| f32(v.to_f/255.0)}
      max=min=r; max=g if greater_than(g,max); max=b if greater_than(b,max); min=g if less_than(g,min); min=b if less_than(b,min)
      l=(max+min)/2.0; return [-1.0,l,0.0] if equals(min,max)
      s=less_than_or_equal(l,0.5) ? (max-min)/(max+min) : (max-min)/(2.0-max-min)
      rc=(max-r)/(max-min); gc=(max-g)/(max-min); bc=(max-b)/(max-min)
      h=equals(r,max) ? bc-gc : equals(g,max) ? 2.0+rc-bc : 4.0+gc-rc
      h*=60.0; h+=360.0 if less_than(h,0.0); [h,l,s]
    end
    def hls2rgb(h,l,s)
      m2=less_than(l,0.5) ? l*(1.0+s) : l+s-(l*s); m1=2.0*l-m2
      [calc(m1,m2,h+120.0),calc(m1,m2,h),calc(m1,m2,h-120.0)].map{|v| double2byte(v)}
    end
    def calc(n1,n2,h)
      h-=360.0 if greater_than(h,360.0); h+=360.0 if less_than(h,0.0)
      return n1+(n2-n1)*h/60.0 if less_than(h,60.0); return n2 if less_than(h,180.0)
      return n1+(n2-n1)*(240.0-h)/60.0 if less_than(h,240.0); n1
    end
    def f32(v); [v].pack('e').unpack1('e'); end
    def less_than(a,b); (a-b)<=-EQUAL_TOL; end
    def greater_than(a,b); (a-b)>=EQUAL_TOL; end
    def equals(a,b); (a-b).abs<EQUAL_TOL; end
    def less_than_or_equal(a,b); less_than(a,b)||equals(a,b); end
    def clamp(v,min,max); [[v,min].max,max].min; end
    def double2byte(v); return 0 if v<=0.0; return 255 if v>=1.0; (v*255.0).to_i; end
    private_class_method :rgb2hls,:hls2rgb,:calc,:f32,:less_than,:greater_than,:equals,:less_than_or_equal,:clamp,:double2byte
  end
end
