require "./event_libevent"

class Thread
  # :nodoc:
  getter(event_base) { Crystal::Event::Base.new }

  @exit_event : Crystal::Event?

  # :nodoc:
  def exit_event : Crystal::Event
    if (event = @exit_event)
      event
    else
      @exit_event = event_base.new_event(-1, LibEvent2::EventFlags::Persist, self) do |s, flags, data|
        data.as(Thread).event_base.loop_exit
      end
    end
  end

  @hang_event : Crystal::Event?

  # :nodoc:
  def hang_event : Crystal::Event
    if (event = @hang_event)
      event
    else
      @hang_event = event_base.new_event(-1, LibEvent2::EventFlags::Read, nil) { }
    end
  end
end

module Crystal::EventLoop
  {% unless flag?(:preview_mt) %}
    # Reinitializes the event loop after a fork.
    def self.after_fork : Nil
      event_base.reinit
    end
  {% end %}

  # Runs the event loop.
  def self.run_once
    event_base.run_once
  end

  def self.run_loop
    event_base.run_loop
  end

  private def self.event_base
    Thread.current.event_base
  end

  # Create a new resume event for a fiber.
  def self.create_resume_event(fiber : Fiber) : Crystal::Event
    event_base.new_event(-1, LibEvent2::EventFlags::None, fiber) do |s, flags, data|
      Crystal::Scheduler.enqueue data.as(Fiber)
    end
  end

  # Creates a write event for a file descriptor.
  def self.create_fd_write_event(io : IO::Evented, edge_triggered : Bool = false) : Crystal::Event
    flags = LibEvent2::EventFlags::Write
    flags |= LibEvent2::EventFlags::Persist | LibEvent2::EventFlags::ET if edge_triggered

    event_base.new_event(io.fd, flags, io) do |s, flags, data|
      io_ref = data.as(typeof(io))
      if flags.includes?(LibEvent2::EventFlags::Write)
        io_ref.resume_write
      elsif flags.includes?(LibEvent2::EventFlags::Timeout)
        io_ref.resume_write(timed_out: true)
      end
    end
  end

  # Creates a read event for a file descriptor.
  def self.create_fd_read_event(io : IO::Evented, edge_triggered : Bool = false) : Crystal::Event
    flags = LibEvent2::EventFlags::Read
    flags |= LibEvent2::EventFlags::Persist | LibEvent2::EventFlags::ET if edge_triggered

    event_base.new_event(io.fd, flags, io) do |s, flags, data|
      io_ref = data.as(typeof(io))
      if flags.includes?(LibEvent2::EventFlags::Read)
        io_ref.resume_read
      elsif flags.includes?(LibEvent2::EventFlags::Timeout)
        io_ref.resume_read(timed_out: true)
      end
    end
  end
end
