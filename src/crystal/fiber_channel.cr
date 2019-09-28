require "./spin_lock"
require "./event_loop"
require "static_list"

# :nodoc:
class Crystal::FiberChannel
  struct Receiver
    getter event : Crystal::Event
    property fiber : Fiber?

    def initialize(@event : Crystal::Event)
      @link = uninitialized StaticList
    end

    def receive_from(ch : FiberChannel)
      ch.@mutex.lock
      if _fiber = ch.@pending_fibers.shift?
        ch.@mutex.unlock

        @fiber = container_of(_fiber, Fiber, @pending_link)
        true
      else
        @link.append_to pointerof(ch.@receivers)
        ch.@mutex.unlock
        false
      end
    end
  end

  @mutex = Crystal::SpinLock.new

  def initialize
    @pending_fibers = uninitialized StaticList
    @pending_fibers.init

    @receivers = uninitialized StaticList
    @receivers.init
  end

  def send(fiber : Fiber)
    @mutex.lock
    if link = @receivers.shift?
      @mutex.unlock

      receiver = container_of(link, Receiver, @link)
      receiver.value.fiber = fiber
      receiver.value.event.active
    else
      fiber.@pending_link.append_to pointerof(@pending_fibers)
      @mutex.unlock
    end
  end

  def try_receive?
    @mutex.lock
    _fiber = @pending_fibers.shift?
    @mutex.unlock

    _fiber.try { |ptr| container_of(ptr, Fiber, @pending_link) }
  end

  def send_first(fiber : Fiber)
    @mutex.lock
    if link = @receivers.shift?
      @mutex.unlock

      receiver = container_of(link, Receiver, @link)
      receiver.value.fiber = fiber
      receiver.value.event.active
    else
      fiber.@pending_link.prepend_to pointerof(@pending_fibers)
      @mutex.unlock
    end
  end
end
