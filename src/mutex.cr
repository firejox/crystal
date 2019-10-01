require "crystal/spin_lock"
require "static_list"

# A fiber-safe mutex.
class Mutex
  @mutex_fiber : Fiber?

  def initialize
    @lock_count = 0
    @lock = Crystal::SpinLock.new
    @list = uninitialized StaticList
    @list.init
  end

  def lock
    @lock.lock
    mutex_fiber = @mutex_fiber
    current_fiber = Fiber.current

    if !mutex_fiber
      @mutex_fiber = current_fiber
      @lock.unlock
    elsif mutex_fiber == current_fiber
      @lock_count += 1 # recursive lock
      @lock.unlock
    else
      Fiber.current.@waiting_link.append_to pointerof(@list)
      {% if flag?(:preview_mt) %}
        Crystal::Scheduler.reschedule_internal do |fiber|
          fiber.add_spin_unlock_helper @lock
        end
      {% else %}
        @lock.unlock
        Crystal::Scheduler.reschedule
      {% end %}
    end

    nil
  end

  def unlock
    @lock.lock

    unless @mutex_fiber == Fiber.current
      @lock.unlock
      raise "Attempt to unlock a mutex which is not locked"
    end

    if @lock_count > 0
      @lock_count -= 1
      @lock.unlock
      return
    end

    if link = @list.shift?
      @mutex_fiber = fiber = container_of(link, Fiber, @waiting_link)
      @lock.unlock
      fiber.enqueue
    else
      @mutex_fiber = nil
      @lock.unlock
    end

    nil
  end

  def synchronize
    lock
    begin
      yield
    ensure
      unlock
    end
  end
end
