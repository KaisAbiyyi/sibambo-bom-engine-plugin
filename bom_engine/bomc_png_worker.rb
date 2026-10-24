# frozen_string_literal: true
require 'tmpdir'
require 'fileutils'
require 'digest'
require_relative 'bomc_processing'
require_relative 'windows_codec_process'

module BOMEngine
  # Reuses the existing cancellable Windows codec-process boundary. SDK calls
  # occur on the caller; this helper consumes only detached byte buffers/files.
  module BOMCPngWorker
    module_function
    def available?
      Gem.win_platform? && File.file?(powershell) && File.file?(script)
    end
    def powershell
      File.join(ENV.fetch('SystemRoot','C:/Windows'),'System32/WindowsPowerShell/v1.0/powershell.exe')
    end
    def script
      File.join(__dir__,'bin/win64/exact_png_worker.ps1')
    end
    def execute(mode,raw,width,height,channels,padding,bgr,directory,checkpoint)
      return nil unless available?
      checkpoint.call(0,width*height,:png_worker_prepare) if checkpoint
      Dir.mktmpdir('.png-work-',directory) do |temp|
        input=File.join(temp,'input.bin');output=File.join(temp,mode=='frame' ? 'output.png' : 'output.bin')
        File.open(input,'wb') do |io|
          offset=0
          while offset<raw.bytesize
            checkpoint.call(0,width*height,:png_worker_input) if checkpoint
            io.write(raw.byteslice(offset,1_048_576));offset+=1_048_576
          end
        end
        args=[powershell,'-NoProfile','-NonInteractive','-File',script,
          '-Mode',mode,'-InputPath',input,'-OutputPath',output,'-Width',width.to_s,'-Height',height.to_s,
          '-Channels',channels.to_s,'-Padding',padding.to_s,'-Bgr',bgr.to_s,
          '-CachePath',File.join(directory,'.png-worker-cache')]
        code=WindowsCodecProcess.run(args,timeout_sec: 60.0,
          checkpoint: checkpoint && -> {checkpoint.call(0,width*height,:png_worker)},
          stderr_path:File.join(temp,'stderr.txt'))
        raise IOError,"PNG worker failed (#{code}): #{File.read(File.join(temp,'stderr.txt'))[0,1200]}" unless code==0 && File.file?(output)
        result=File.binread(output)
        checkpoint.call(width*height,width*height,:png_worker_complete) if checkpoint
        result
      end
    rescue WindowsCodecProcess::CancelledError => error
      raise BOMCProcessing::Cancelled,error.message
    rescue WindowsCodecProcess::ProcessError => error
      raise IOError, error.message
    end
    def filter(raw:,width:,height:,bpp:,directory:,checkpoint:nil)
      result=execute('filter',raw,width,height,bpp,0,false,directory,checkpoint)
      raise IOError,'PNG worker returned wrong filter byte count' if result && result.bytesize!=height*(width*bpp+1)
      result
    end
    def write_frame(image,path,checkpoint:nil)
      width=Integer(image.width);height=Integer(image.height);bits=Integer(image.bits_per_pixel);padding=Integer(image.row_padding)
      raise ArgumentError,'Invalid PNG frame dimensions/layout' unless width>0 && height>0 && width*height<=32_000_000 && [24,32].include?(bits) && padding>=0
      data=image.data
      raise ArgumentError,'Invalid PNG frame byte count' unless data.is_a?(String) && data.bytesize==(width*(bits/8)+padding)*height
      bytes=execute('frame',data,width,height,bits/8,padding,Gem.win_platform?,File.dirname(path),checkpoint)
      return false unless bytes
      raise IOError,'PNG worker did not produce a PNG' unless bytes.start_with?("\x89PNG\r\n\x1a\n".b)
      File.binwrite(path,bytes)
      true
    end
  end
end
