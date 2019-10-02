require "static_list"

# :nodoc:
class Crystal::FiberChannel
  struct Receiver
    @event : Crystal::Event
    @fiber : Fiber?

    def initialize(event : Crystal::Event)
      @event = event
      @link = uninitialized StaticList
    end

    def receive_from(ch : FiberChannel) : Bool
      ch.@mutex.lock
      if _fiber = ch.@fibers.shift?
        ch.@mutex.unlock
        @fiber = container_of(_fiber, Fiber, @waiting_link)
        true
      else
        @link.append_to pointerof(ch.@receivers)
        ch.@mutex.unlock
        false
      end
    end

    protected def fiber=(_fiber : Fiber)
      @fiber = _fiber
    end
  end

  def initialize
    @mutex = Crystal::SpinLock.new
    @fibers = uninitialized StaticList
    @fibers.init
    @receivers = uninitialized StaticList
    @receivers.init
  end

  def send(fiber : Fiber) : Nil
    @mutex.lock
    if _receiver = @receivers.shift?
      @mutex.unlock
      receiver = container_of(_receiver, Receiver, @link)
      receiver.value.fiber = fiber
      receiver.value.@event.active
    else
      fiber.@waiting_link.append_to pointerof(@fibers)
      @mutex.unlock
    end
  end

  def try_receive? : Fiber?
    @mutex.lock
    _fiber = @fibers.shift?
    @mutex.unlock

    _fiber.try { |f| container_of(f, Fiber, @waiting_link) }
  end
end
