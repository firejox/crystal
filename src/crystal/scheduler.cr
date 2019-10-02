require "./event_loop"
require "./fiber_channel"
require "fiber"
require "thread"

# :nodoc:
#
# Schedulers are tied to a thread, and must only ever be accessed from within
# this thread.
#
# Only the class methods are public and safe to use. Instance methods are
# protected and must never be called directly.
class Crystal::Scheduler
  def self.current_fiber : Fiber
    Thread.current.scheduler.@current
  end

  def self.enqueue(fiber : Fiber) : Nil
    {% if flag?(:preview_mt) %}
      th = fiber.@current_thread.lazy_get

      if th.nil?
        th = Thread.current.scheduler.find_target_thread
      end

      th.scheduler.enqueue(fiber)
    {% else %}
      Thread.current.scheduler.enqueue(fiber)
    {% end %}
  end

  def self.enqueue(fibers : Enumerable(Fiber)) : Nil
    fibers.each do |fiber|
      enqueue(fiber)
    end
  end

  def self.reschedule_internal : Nil
    Thread.current.scheduler.reschedule do |fiber|
      yield fiber
    end
  end

  def self.reschedule : Nil
    {% if flag?(:preview_mt) %}
      self.reschedule_internal { nil }
    {% else %}
      self.reschedule_internal { |fiber| return if fiber.running? }
    {% end %}
  end

  def self.resume(fiber : Fiber) : Nil
    Thread.current.scheduler.resume(fiber)
  end

  def self.sleep(time : Time::Span) : Nil
    Thread.current.scheduler.sleep(time)
  end

  def self.yield : Nil
    Thread.current.scheduler.yield
  end

  def self.yield(fiber : Fiber) : Nil
    Thread.current.scheduler.yield(fiber)
  end

  {% if flag?(:preview_mt) %}
    @loop_fiber : Fiber?
  {% end %}

  # :nodoc:
  def initialize(@main : Fiber)
    @current = @main
    @fiber_channel = Crystal::FiberChannel.new
  end

  protected def enqueue(fiber : Fiber) : Nil
    # TODO some bugs in other place will send dead fiber
    @fiber_channel.send fiber unless fiber.dead?
  end

  protected def enqueue(fibers : Enumerable(Fiber)) : Nil
    fibers.each { |fiber| enqueue fiber }
  end

  protected def resume(fiber : Fiber) : Nil
    validate_resumable(fiber)
    {% if flag?(:preview_mt) %}
      set_current_thread(fiber)
      GC.lock_read
      fiber.add_gc_read_unlock_helper
    {% else %}
      GC.set_stackbottom(fiber.@stack_bottom)
    {% end %}

    current, @current = @current, fiber
    Fiber.swapcontext(pointerof(current.@context), pointerof(fiber.@context))
  end

  private def validate_resumable(fiber)
    return if fiber.resumable?

    if fiber.dead?
      fatal_resume_error(fiber, "tried to resume a dead fiber")
    else
      fatal_resume_error(fiber, "can't resume a running fiber")
    end
  end

  private def set_current_thread(fiber)
    fiber.@current_thread.set(Thread.current)
  end

  private def fatal_resume_error(fiber, message)
    LibC.dprintf 2, "\nFATAL: #{message}: #{fiber}\n"
    caller.each { |line| LibC.dprintf(2, "  from #{line}\n") }
    exit 1
  end

  protected def reschedule : Nil
    {% if flag?(:preview_mt) %}
      resume channel_receive_non_block.tap { |fiber| yield fiber }
    {% else %}
      resume channel_receive.tap { |fiber| yield fiber }
    {% end %}
  end

  protected def sleep(time : Time::Span) : Nil
    @current.resume_event.add(time)
    reschedule { nil }
  end

  protected def yield : Nil
    sleep(0.seconds)
  end

  protected def yield(fiber : Fiber) : Nil
    @current.resume_event.add(0.seconds)
    resume(fiber)
  end

  protected def channel_receive : Fiber
    th = Thread.current
    th.exit_event.add

    receiver = Crystal::FiberChannel::Receiver.new th.resume_event

    unless receiver.receive_from @fiber_channel
      Crystal::EventLoop.run_loop
    end

    th.exit_event.remove
    receiver.@fiber.not_nil!
  end

  {% if flag?(:preview_mt) %}
    protected def loop_fiber=(fiber : Fiber)
      @loop_fiber = fiber
    end

    protected def loop_fiber : Fiber
      @loop_fiber.not_nil!
    end

    @rr_target = 0

    protected def find_target_thread
      if workers = @@workers
        @rr_target += 1
        workers[@rr_target % workers.size]
      else
        Thread.current
      end
    end

    protected def channel_receive_non_block : Fiber
      if fiber = @fiber_channel.try_receive?
        fiber
      else
        loop_fiber
      end
    end

    def run_loop
      loop do
        resume channel_receive
      end
    end

    def self.init_workers
      count = worker_count
      pending = Atomic(Int32).new(count - 1)
      @@workers = Array(Thread).new(count) do |i|
        if i == 0
          worker_loop = Fiber.new(name: "Worker Loop") { Thread.current.scheduler.run_loop }
          Thread.current.scheduler.loop_fiber = worker_loop
          Thread.current
        else
          Thread.new do
            scheduler = Thread.current.scheduler
            scheduler.loop_fiber = scheduler.@main
            pending.sub(1)
            scheduler.run_loop
          end
        end
      end

      # Wait for all worker threads to be fully ready to be used
      while pending.get > 0
        Fiber.yield
      end
    end

    private def self.worker_count
      env_workers = ENV["CRYSTAL_WORKERS"]?

      if env_workers && !env_workers.empty?
        workers = env_workers.to_i?
        if !workers || workers < 1
          LibC.dprintf 2, "FATAL: Invalid value for CRYSTAL_WORKERS: #{env_workers}\n"
          exit 1
        end

        workers
      else
        # TODO: default worker count, currenlty hardcoded to 4 that seems to be something
        # that is benefitial for many scenarios without adding too much contention.
        # In the future we could use the number of cores or something associated to it.
        4
      end
    end
  {% end %}
end
