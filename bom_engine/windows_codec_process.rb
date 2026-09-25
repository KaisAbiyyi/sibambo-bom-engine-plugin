# frozen_string_literal: true
require 'fiddle/import'

module BOMEngine
  # SketchUp's embedded MSVC Ruby process/CRT inheritance can stall native
  # codecs or lose redirected output. Start .exe codecs directly, with only
  # our three private standard handles inherited; never invoke a shell.
  module WindowsCodecProcess
    class ProcessError < StandardError; end
    class TimeoutError < ProcessError; end
    class CancelledError < ProcessError; end

    if Gem.win_platform?
      module Native
        extend Fiddle::Importer
        dlload 'kernel32.dll'
        extern 'int CreateProcessW(void*, void*, void*, void*, int, unsigned int, void*, void*, void*, void*)'
        extern 'void* CreateFileW(void*, unsigned int, unsigned int, void*, unsigned int, unsigned int, void*)'
        extern 'int InitializeProcThreadAttributeList(void*, unsigned int, unsigned int, void*)'
        extern 'int UpdateProcThreadAttribute(void*, unsigned int, size_t, void*, size_t, void*, void*)'
        extern 'void DeleteProcThreadAttributeList(void*)'
        extern 'unsigned int WaitForSingleObject(void*, unsigned int)'
        extern 'int GetExitCodeProcess(void*, void*)'
        extern 'int TerminateProcess(void*, unsigned int)'
        extern 'int CloseHandle(void*)'
        extern 'unsigned int GetLastError()'
        Security = struct ['unsigned int length', 'void* descriptor', 'int inherit']
        Startup = struct [
          'unsigned int cb', 'void* reserved', 'void* desktop', 'void* title',
          'unsigned int x', 'unsigned int y', 'unsigned int xsize', 'unsigned int ysize',
          'unsigned int xcount', 'unsigned int ycount', 'unsigned int fill', 'unsigned int flags',
          'unsigned short show', 'unsigned short reserved_size', 'void* reserved_data',
          'void* stdin_handle', 'void* stdout_handle', 'void* stderr_handle', 'void* attributes'
        ]
        Information = struct ['void* process', 'void* thread', 'unsigned int pid', 'unsigned int tid']
      end
    end

    module_function

    def wide(value)
      raise ArgumentError, 'NUL in process argument/path' if value.include?("\0")
      (value.encode(Encoding::UTF_16LE).b + "\0\0".b)
    end

    # Microsoft CRT argv quoting; metacharacters remain data (no cmd.exe).
    def quote(value)
      '"' + value.gsub(/(\\*)"/) { '\\' * (Regexp.last_match(1).length * 2 + 1) + '"' }
        .sub(/\\+\z/) { |tail| tail * 2 } + '"'
    end

    def checked(result, operation)
      raise ProcessError, "#{operation} failed (Windows error #{Native.GetLastError})" if result == 0
      result
    end

    def native_struct(type, owned)
      pointer = Fiddle::Pointer.malloc(type.size, Fiddle::RUBY_FREE)
      pointer[0, type.size] = "\0" * type.size
      owned << pointer # Keep the backing allocation alive through the native call.
      type.new(pointer)
    end

    def open_handle(path, owned:, input: false)
      security = native_struct(Native::Security, owned)
      security.length = Native::Security.size
      security.descriptor = 0
      security.inherit = 1
      handle = Native.CreateFileW(wide(path), input ? 0x80000000 : 0x40000000,
        3, security, input || path == File::NULL ? 3 : 2, 0x80, 0)
      invalid = (1 << (Fiddle::SIZEOF_VOIDP * 8)) - 1
      raise ProcessError, "CreateFileW failed (Windows error #{Native.GetLastError})" if handle.to_i == invalid || handle.to_i == -1
      handle
    end

    def run(args, timeout_sec:, checkpoint: nil, stdout_path: nil, stderr_path: nil)
      raise ProcessError, 'Windows codec runner requires Windows' unless Gem.win_platform?
      raise ArgumentError, 'Expected a .exe and string arguments' unless args.is_a?(Array) && !args.empty? &&
        args.all? { |arg| arg.is_a?(String) && !arg.include?("\0") } && File.extname(args.first).downcase == '.exe'
      raise ArgumentError, 'Timeout must be finite and positive' unless timeout_sec.is_a?(Numeric) && timeout_sec.finite? && timeout_sec.positive?
      application = wide(File.expand_path(args.first))
      command = wide(args.map { |arg| quote(arg) }.join(' '))
      raise ArgumentError, 'Command line too long' if command.bytesize / 2 > 32_767

      handles = []
      attributes = nil
      initialized = false
      process = nil
      finished = false
      begin
        owned = []
        handles << open_handle(File::NULL, owned: owned, input: true)
        handles << open_handle(stdout_path || File::NULL, owned: owned)
        handles << open_handle(stderr_path || File::NULL, owned: owned)
        size = [0].pack('J')
        Native.InitializeProcThreadAttributeList(0, 1, 0, size)
        attributes = Fiddle::Pointer.malloc(size.unpack1('J'), Fiddle::RUBY_FREE)
        checked(Native.InitializeProcThreadAttributeList(attributes, 1, 0, size), 'InitializeProcThreadAttributeList')
        initialized = true
        inherited = handles.map(&:to_i).pack('J*')
        checked(Native.UpdateProcThreadAttribute(attributes, 0, 0x20002, inherited, inherited.bytesize, 0, 0), 'UpdateProcThreadAttribute')
        startup = native_struct(Native::Startup, owned)
        startup.cb = Native::Startup.size
        startup.flags = 0x100 # STARTF_USESTDHANDLES
        startup.stdin_handle, startup.stdout_handle, startup.stderr_handle = handles
        startup.attributes = attributes
        info = native_struct(Native::Information, owned)
        # EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW. Explicit application
        # path prevents executable-name ambiguity; whitelist prevents SKP locks.
        checked(Native.CreateProcessW(application, command, 0, 0, 1, 0x08080000, 0, 0, startup, info), 'CreateProcessW')
        process = info.process
        Native.CloseHandle(info.thread)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        loop do
          wait = Native.WaitForSingleObject(process, 20)
          if wait == 0
            finished = true
            code = [0].pack('L')
            checked(Native.GetExitCodeProcess(process, code), 'GetExitCodeProcess')
            return code.unpack1('L')
          end
          raise ProcessError, "WaitForSingleObject failed (Windows error #{Native.GetLastError})" unless wait == 258
          begin
            checkpoint.call if checkpoint
          rescue StandardError => error
            raise CancelledError, "Transcoding cancelled: #{error.message}"
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= timeout_sec
            raise TimeoutError, "Transcoder timed out after #{timeout_sec}s"
          end
        end
      ensure
        if process
          unless finished
            Native.TerminateProcess(process, 1)
            Native.WaitForSingleObject(process, 1000)
          end
          Native.CloseHandle(process)
        end
        Native.DeleteProcThreadAttributeList(attributes) if initialized
        handles.each { |handle| Native.CloseHandle(handle) }
      end
    end
    private_class_method :wide, :quote, :checked, :native_struct, :open_handle
  end
end
