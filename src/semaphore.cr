require "crystal/spin_lock"
require "static_list"

class Semaphore
  @count : Int32

  def initialize(@count : Int32, @blocking = false)
    @mutex = Crystal::SpinLock.new
    @list = uninitialized StaticList
    @list.init
  end

  def wait
    @mutex.lock
    @count -= 1
    if @count < 0
      Fiber.current.@waiting_link.append_to pointerof(@list)
      {% if flag?(:preview_mt) %}
        Crystal::Scheduler.reschedule_internal do |fiber|
          fiber.add_spin_unlock_helper @mutex
        end
      {% else %}
        @mutex.unlock
        Crystal::Scheduler.reschedule
      {% end %}
    else
      @mutex.unlock
    end
  end

  def signal
    @mutex.lock
    @count += 1
    if @count <= 0
      link = @list.shift
      @mutex.unlock

      if @blocking
        Crystal::Scheduler.yield container_of(link, Fiber, @waiting_link)
      else
        Crystal::Scheduler.enqueue container_of(link, Fiber, @waiting_link)
      end
    else
      @mutex.unlock
    end
  end

  def reset(c : Int32)
    list = StaticList.new
    list.init
    @mutex.lock
    @count = c
    @list.list_append_to pointerof(list)
    @mutex.unlock

    list.each do |it|
      Crystal::Scheduler.enqueue container_of(it, Fiber, @waiting_link)
    end
  end
end
