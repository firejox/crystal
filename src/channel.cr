require "fiber"
require "crystal/spin_lock"
require "static_list"

# A `Channel` enables concurrent communication between fibers.
#
# They allow communicating data between fibers without sharing memory and without having to worry about locks, semaphores or other special structures.
#
# ```
# channel = Channel(Int32).new
#
# spawn do
#   channel.send(0)
#   channel.send(1)
# end
#
# channel.receive # => 0
# channel.receive # => 1
# ```

class Channel(T)
  @lock = Crystal::SpinLock.new
  @queue : Deque(T)?

  module NotReady
    extend self
  end

  module Closed
    extend self
  end

  module SelectAction(S)
    abstract def execute : TransferState
    abstract def wait(context : SelectContext(S))
    abstract def unwait
    abstract def result : Closed | S
    abstract def lock_object_id
    abstract def lock
    abstract def unlock

    def create_context_and_wait(state_ptr)
      context = SelectContext.new(state_ptr, self)
      self.wait(context)
      context
    end
  end

  enum SelectState
    None   = 0
    Active = 1
    Done   = 2
  end

  private class SelectContext(S)
    @state : Pointer(Atomic(SelectState))
    property action : SelectAction(S)
    @activated = false

    def initialize(@state, @action : SelectAction(S))
    end

    def activated?
      @activated
    end

    def try_trigger : Bool
      _, succeed = @state.value.compare_and_set(SelectState::Active, SelectState::Done)
      if succeed
        @activated = true
      end
      succeed
    end
  end

  class ClosedError < Exception
    def initialize(msg = "Channel is closed")
      super(msg)
    end
  end

  enum TransferState
    None
    Succeed
    Closed
  end

  private struct Sender(T)
    def initialize(@fiber : Fiber, @value : T, @state : TransferState, @select_context : SelectContext(Nil)?)
      @link = uninitialized StaticList
    end

    def fiber=(@fiber : Fiber)
    end

    def state=(@state : TransferState)
    end

    def select_context=(@select_context : SelectContext(T))
    end
  end

  private struct Receiver(T)
    def initialize(@fiber : Fiber, @state : TransferState, @select_context : SelectContext(T)?)
      @value = uninitialized T
      @link = uninitialized StaticList
    end

    def fiber=(@fiber : Fiber)
    end

    def value=(@value : T)
    end

    def state=(@state : TransferState)
    end

    def select_context=(@select_context : SelectContext(T))
    end
  end

  def initialize(@capacity = 0)
    @closed = false

    @senders = uninitialized StaticList
    @senders.init

    @receivers = uninitialized StaticList
    @receivers.init

    if capacity > 0
      @queue = Deque(T).new(capacity)
    end
  end

  def close : Nil
    senders = uninitialized StaticList
    senders.init

    receivers = uninitialized StaticList
    receivers.init

    @lock.sync do
      @closed = true
      @senders.list_append_to pointerof(senders)
      @receivers.list_append_to pointerof(receivers)
    end

    senders.each do |it|
      sender_ptr = container_of(it, Sender(T), @link)

      if (select_context = sender_ptr.value.@select_context) && !select_context.try_trigger
        next
      else
        sender_ptr.value.state = TransferState::Closed
        sender_ptr.value.@fiber.enqueue
      end
    end

    receivers.each do |it|
      receiver_ptr = container_of(it, Receiver(T), @link)

      if (select_context = receiver_ptr.value.@select_context) && !select_context.try_trigger
        next
      else
        receiver_ptr.value.state = TransferState::Closed
        receiver_ptr.value.@fiber.enqueue
      end
    end
  end

  def closed?
    @closed
  end

  def send(value : T)
    sender = Sender(T).new(Fiber.current, value, TransferState::None, select_context: nil)

    @lock.lock

    state, receiver_fiber = send_internal(value)

    case state
    when TransferState::Closed
      @lock.unlock
      raise ClosedError.new
    when TransferState::Succeed
      @lock.unlock
      receiver_fiber.try &.enqueue
    else
      sender.@link.append_to pointerof(@senders)

      {% if flag?(:preview_mt) %}
        Crystal::Scheduler.reschedule_internal do |fiber|
          fiber.add_spin_unlock_helper @lock
        end
      {% else %}
        @lock.unlock
        Crystal::Scheduler.reschedule
      {% end %}

      state = sender.@state
      if state == TransferState::Closed
        raise ClosedError.new
      elsif state != TransferState::Succeed
        raise "BUG: Fiber was awaken without channel transfer state set"
      end
    end

    self
  end

  protected def send_internal(value : T)
    if @closed
      {TransferState::Closed, nil}
    elsif receiver_ptr = dequeue_receiver
      receiver_ptr.value.value = value
      receiver_ptr.value.state = TransferState::Succeed
      {TransferState::Succeed, receiver_ptr.value.@fiber}
    elsif (queue = @queue) && queue.size < @capacity
      queue << value
      {TransferState::Succeed, nil}
    else
      {TransferState::None, nil}
    end
  end

  # Receives a value from the channel.
  # If there is a value waiting, it is returned immediately. Otherwise, this method blocks until a value is sent to the channel.
  #
  # Raises `ClosedError` if the channel is closed or closes while waiting for receive.
  #
  # ```
  # channel = Channel(Int32).new
  # channel.send(1)
  # channel.receive # => 1
  # ```
  def receive
    receive_impl { raise ClosedError.new }
  end

  # Receives a value from the channel.
  # If there is a value waiting, it is returned immediately. Otherwise, this method blocks until a value is sent to the channel.
  #
  # Returns `nil` if the channel is closed or closes while waiting for receive.
  def receive?
    receive_impl { return nil }
  end

  def receive_impl
    receiver = Receiver(T).new(Fiber.current, TransferState::None, select_context: nil)

    @lock.lock

    state, value, sender_fiber = receive_internal

    case state
    when TransferState::Succeed
      @lock.unlock
      sender_fiber.try &.enqueue
      value
    when TransferState::Closed
      @lock.unlock
      yield
    else
      receiver.@link.append_to pointerof(@receivers)

      {% if flag?(:preview_mt) %}
        Crystal::Scheduler.reschedule_internal do |fiber|
          fiber.add_spin_unlock_helper @lock
        end
      {% else %}
        @lock.unlock
        Crystal::Scheduler.reschedule
      {% end %}

      case receiver.@state
      when TransferState::Succeed
        receiver.@value
      when TransferState::Closed
        yield
      else
        raise "BUG: Fiber was awaken without channel transfer state set"
      end
    end
  end

  def receive_internal
    dummy_value = uninitialized T

    if (queue = @queue) && !queue.empty?
      deque_value = queue.shift
      if sender_ptr = dequeue_sender
        sender_ptr.value.state = TransferState::Succeed
        queue << sender_ptr.value.@value
      end

      {TransferState::Succeed, deque_value, sender_ptr.try { |ptr| ptr.value.@fiber }}
    elsif sender_ptr = dequeue_sender
      sender_ptr.value.state = TransferState::Succeed

      {TransferState::Succeed, sender_ptr.value.@value, sender_ptr.value.@fiber}
    elsif @closed
      {TransferState::Closed, dummy_value, nil}
    else
      {TransferState::None, dummy_value, nil}
    end
  end

  private def dequeue_receiver
    while receiver_ptr = container_of?(@receivers.shift?, Receiver(T), @link)
      if (select_context = receiver_ptr.value.@select_context) && !select_context.try_trigger
        receiver_ptr.value.@link.init
        next
      end

      break
    end

    receiver_ptr
  end

  private def dequeue_sender
    while sender_ptr = container_of?(@senders.shift?, Sender(T), @link)
      if (select_context = sender_ptr.value.@select_context) && !select_context.try_trigger
        sender_ptr.value.@link.init
        next
      end

      break
    end

    sender_ptr
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end

  def pretty_print(pp)
    pp.text inspect
  end

  def self.receive_first(*channels)
    receive_first channels
  end

  def self.receive_first(channels : Tuple | Array)
    _, value = self.select(channels.map(&.receive_select_action))
    if value.is_a?(NotReady)
      raise "BUG: Channel.select returned not ready status"
    end

    value
  end

  def self.send_first(value, *channels)
    send_first value, channels
  end

  def self.send_first(value, channels : Tuple | Array)
    self.select(channels.map(&.send_select_action(value)))
    nil
  end

  def self.select(*ops : SelectAction)
    self.select ops
  end

  def self.select(ops : Indexable(SelectAction), has_else = false)
    # Sort the operations by the channel they contain
    # This is to avoid deadlocks between concurrent `select` calls
    ops_locks = ops
      .to_a
      .uniq(&.lock_object_id)
      .sort_by(&.lock_object_id)

    ops_locks.each &.lock

    ops.each_with_index do |op, index|
      ignore = false
      result = op.execute

      unless result == TransferState::None
        ops_locks.each &.unlock
        return index, op.result
      end
    end

    if has_else
      ops_locks.each &.unlock
      return ops.size, NotReady
    end

    state = Atomic(SelectState).new(SelectState::Active)
    contexts = ops.map &.create_context_and_wait(pointerof(state))

    {% if flag?(:preview_mt) %}
      Crystal::Scheduler.reschedule_internal do |fiber|
        fiber.add_select_actions_unlock_helper ops_locks
      end
    {% else %}
      ops_locks.each &.unlock
      Crystal::Scheduler.reschedule
    {% end %}

    ops.each do |op|
      op.lock
      op.unwait
      op.unlock
    end

    contexts.each_with_index do |context, index|
      if context.activated?
        return index, context.action.result
      end
    end

    raise "BUG: Fiber was awaken from select but no action was activated"
  end

  # :nodoc:
  def send_select_action(value : T)
    SendAction.new(self, value)
  end

  # :nodoc:
  def receive_select_action
    ReceiveAction.new(self)
  end

  # :nodoc:
  class ReceiveAction(T)
    include SelectAction(T)

    def initialize(@channel : Channel(T))
      @receiver = uninitialized Receiver(T)
    end

    def execute : TransferState
      state, value, fiber = @channel.receive_internal

      fiber.try &.enqueue

      @receiver.value = value
      @receiver.state = state
    end

    def result : Channel::Closed | T
      case @receiver.@state
      when TransferState::Succeed
        @receiver.@value
      when TransferState::Closed
        Channel::Closed
      else
        raise "BUG : Fiber was awaken but without accepted channel transfer state set"
      end
    end

    def wait(context : SelectContext(T))
      @receiver.fiber = Fiber.current
      @receiver.state = TransferState::None
      @receiver.select_context = context
      @receiver.@link.append_to pointerof(@channel.@receivers)
    end

    def unwait
      if !@channel.closed? && @receiver.@state == TransferState::None
        @receiver.@link.unlink
      end
    end

    def lock_object_id
      @channel.object_id
    end

    def lock
      @channel.@lock.lock
    end

    def unlock
      @channel.@lock.unlock
    end
  end

  # :nodoc:
  class SendAction(T)
    include SelectAction(Nil)

    def initialize(@channel : Channel(T), value : T)
      @sender = uninitialized Sender(T)
      @sender.value = value
    end

    def execute : TransferState
      state, fiber = @channel.send_internal(@sender.@value)

      fiber.try &.enqueue
      @sender.state = state
    end

    def result : Channel::Closed | Nil
      state = @sender.@state

      if state == TransferState::Closed
        raise ClosedError.new
      elsif state != TransferState::Succeed
        raise "BUG: Fiber was awaken but without accepted channel transfer state set"
      end
    end

    def wait(context : SelectContext(Nil))
      @sender.fiber = Fiber.current
      @sender.state = TransferState::None
      @sender.select_context = context
      @sender.@link.append_to pointerof(@channel.@senders)
    end

    def unwait
      if !@channel.closed? && @sender.state == TransferState::None
        @sender.link.unlink
      end
    end

    def lock_object_id
      @channel.object_id
    end

    def lock
      @channel.@lock.lock
    end

    def unlock
      @channel.@lock.unlock
    end
  end
end
