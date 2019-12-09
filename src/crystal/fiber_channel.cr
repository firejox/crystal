# :nodoc:
#
# This channel is for sending and receiving fibers between worker threads.
# When the local runnable queue is empty, the worker thread will query the
# channel. If the channel is also empty, the worker thread will switch to
# the loop fiber. The thread will register a receiver in channel and run
# event loop. Any other fiber sent into channel will activate the event
# of receiver. The triggered event will exit the event loop.
struct Crystal::FiberChannel
  struct Receiver
    include Crystal::PointerLinkedList::Node

    getter event : Crystal::Event
    property fiber : Fiber?

    def initialize(@event : Crystal::Event)
    end
  end

  def initialize
    @mutex = Crystal::SpinLock.new
    @fibers = Deque(Fiber).new
    @receivers = Crystal::PointerLinkedList(Receiver).new
  end

  def send(fiber : Fiber)
    @mutex.lock
    if receiver_ptr = @receivers.shift?
      @mutex.unlock
      receiver_ptr.value.fiber = fiber
      receiver_ptr.value.event.active
    else
      @fibers.push fiber
      @mutex.unlock
    end
  end

  def try_receive(receiver_ptr : Pointer(Receiver))
    @mutex.lock
    if fiber = @fibers.shift?
      @mutex.unlock
      receiver_ptr.value.fiber = fiber
      true
    else
      @receivers.push receiver_ptr
      @mutex.unlock
      false
    end
  end

  def swap_fibers(fibers : Deque(Fiber))
    @mutex.lock
    current_fibers, @fibers = @fibers, fibers
    @mutex.unlock
    current_fibers
  end
end
