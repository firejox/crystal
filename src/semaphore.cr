require "crystal/spin_lock"
require "static_list"

class Semaphore
  @count : Int32

  def initialize(@count : Int32)
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
      Crystal::Scheduler.enqueue container_of(link, Fiber, @waiting_link)
    else
      @mutex.unlock
    end
  end
end
