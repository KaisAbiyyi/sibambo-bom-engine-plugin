# frozen_string_literal: true

# Process-wide across the namespaced Evolution runtimes. Never reset ownership
# when another runtime requires this file. SketchUp APIs stay on the UI thread.
module SibamboNativeExportLease
  class << self
    def acquire(owner)
      raise 'Another native export owns the SketchUp host.' if @owner && !@owner.equal?(owner)
      @owner = owner
    end

    def release(owner)
      @owner = nil if @owner.equal?(owner)
    end

    def owned?
      !@owner.nil?
    end

    def with_export(owner)
      raise 'Native export lease lost.' unless @owner.equal?(owner)
      previous = @export_fiber
      begin
        @export_fiber = Fiber.current
        yield
      ensure
        @export_fiber = previous
      end
    end

    def direct
      raise 'A BOMC export is already executing.' if @direct_active
      @direct_active = true
      begin
        direct_owned { yield }
      ensure
        @direct_active = false
      end
    end

    def direct_owned
      if @owner
        assert_export_allowed!
        return yield
      end
      token = Object.new
      acquire(token)
      begin
        with_export(token) { yield }
      ensure
        release(token)
      end
    end
    private :direct_owned

    def assert_export_allowed!
      raise 'Overnight batch owns the SketchUp host.' if @owner && @export_fiber != Fiber.current
    end
  end
end
