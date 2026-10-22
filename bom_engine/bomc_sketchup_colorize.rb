# frozen_string_literal: true
require 'digest'

module BOMEngine
  # Byte-exact port of SketchUp's published colorization algorithm.
  module BOMCSketchupColorize
    EQUAL_TOL = 1.0e-3
    module_function

    def verify(uncolorized:, colorized:, mode:, deltas:, checkpoint: nil, max_seconds: nil)
      source=frame(uncolorized); target=frame(colorized)
      return {passed:false,reason: :dimension_mismatch} unless source[:width]==target[:width] && source[:height]==target[:height]
      deadline = max_seconds && Process.clock_gettime(Process::CLOCK_MONOTONIC) + max_seconds
      return {passed:false,reason: :time_budget_exceeded,processed:0} if deadline && max_seconds <= 0
      h,l,s=normalize_deltas(deltas); shift=mode.to_s=='shift'
      # BGRA32 (Windows) / RGBA32 (other hosts) dominates large SketchUp
      # materials. Pack and compare complete native 32-bit pixels in bulk;
      # the published colorization math and strict per-channel proof are
      # identical to the fallback below. 24-bit/mixed layouts stay on the
      # conservative per-pixel implementation.
      if source[:channels] == 4 && target[:channels] == 4
        return verify_rgba32(source,target,h,l,s,shift,checkpoint,deadline)
      end
      digest=Digest::SHA256.new; base_digest=Digest::SHA256.new
      processed=0
      # Memoize only repeated RGB conversions; never cache the observed target.
      # The bounded table avoids unbounded native-host memory on photographic JPEGs.
      color_cache={}
      source[:height].times do |row|
        so=row*source[:stride]; to=row*target[:stride]
        base_row=''.b; output_row=''.b
        source[:width].times do
          sr,sg,sb,sa=logical_rgba(source,so); tr,tg,tb,ta=logical_rgba(target,to)
          rgb_key=(sr<<16)|(sg<<8)|sb
          rgb=color_cache[rgb_key]
          unless rgb
            rgb=colorize_pixel(sr,sg,sb,h,l,s,shift)
            color_cache.clear if color_cache.size>=8192
            color_cache[rgb_key]=rgb
          end
          rr,rg,rb=rgb
          return {passed:false,reason: :pixel_mismatch,processed:processed} unless [rr,rg,rb,sa]==[tr,tg,tb,ta]
          base_row<<sr<<sg<<sb<<sa; output_row<<rr<<rg<<rb<<sa
          so+=source[:channels]; to+=target[:channels]; processed+=1
          if (processed%32_768).zero?
            checkpoint.call(processed,source[:width]*source[:height]) if checkpoint
            if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              return {passed:false,reason: :time_budget_exceeded,processed:processed}
            end
          end
        end
        base_digest.update(base_row); digest.update(output_row)
      end
      {passed:true,width:source[:width],height:source[:height],pixels:processed,
       base_pixel_sha256:base_digest.hexdigest,output_pixel_sha256:digest.hexdigest}
    end

    def verify_rgba32(source,target,h,l,s,shift,checkpoint,deadline)
      width=source[:width]; height=source[:height]; total=width*height
      windows=Gem.win_platform?
      digest=Digest::SHA256.new; base_digest=Digest::SHA256.new
      color_cache={}; processed=0
      height.times do |row|
        base=source[:data].byteslice(row*source[:stride],width*4).unpack('V*')
        displayed=target[:data].byteslice(row*target[:stride],width*4).unpack('V*')
        normalized=Array.new(width); transformed=Array.new(width)
        base.each_with_index do |value,index|
          alpha=value & 0xff000000
          if windows
            blue=value & 255; green=(value>>8)&255; red=(value>>16)&255
          else
            red=value & 255; green=(value>>8)&255; blue=(value>>16)&255
          end
          key=(red<<16)|(green<<8)|blue
          mapped=color_cache[key]
          unless mapped
            rr,rg,rb=colorize_pixel(red,green,blue,h,l,s,shift)
            native=windows ? ((rb)|(rg<<8)|(rr<<16)) : ((rr)|(rg<<8)|(rb<<16))
            rgba=(rr)|(rg<<8)|(rb<<16)
            mapped=[native,rgba]
            color_cache.clear if color_cache.size>=65_536
            color_cache[key]=mapped
          end
          # No tolerance: every RGB channel and alpha byte must match the
          # actual displayed ImageRep, including fully transparent pixels.
          return {passed:false,reason: :pixel_mismatch,processed:processed} unless
            (mapped[0]|alpha)==displayed[index]
          normalized[index]=((red)|(green<<8)|(blue<<16))|alpha
          transformed[index]=mapped[1]|alpha
          processed+=1
          if (processed%32_768).zero?
            checkpoint.call(processed,total) if checkpoint
            if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC)>=deadline
              return {passed:false,reason: :time_budget_exceeded,processed:processed}
            end
          end
        end
        base_digest.update(normalized.pack('V*'))
        digest.update(transformed.pack('V*'))
      end
      {passed:true,width:width,height:height,pixels:processed,
       base_pixel_sha256:base_digest.hexdigest,output_pixel_sha256:digest.hexdigest}
    end
    private_class_method :verify_rgba32

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
