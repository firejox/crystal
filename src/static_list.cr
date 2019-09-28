# :nodoc:
macro container_of(ptr, _type, member)
  {% if _type.resolve <= Reference %}
    (({{ ptr }}).as(Void*) - offsetof({{ _type }}, {{ member }})).as({{ _type }})
  {% else %}
    (({{ ptr }}).as(Void*) - offsetof({{ _type }}, {{ member }})).as(Pointer({{ _type }}))
  {% end %}
end

# :nodoc:
struct StaticList
  @prev = uninitialized Pointer(StaticList)
  @next = uninitialized Pointer(StaticList)

  def prev
    @prev
  end

  def prev=(@prev)
  end

  def next
    @next
  end

  def next=(@next)
  end

  def self_pointer
    (->self.itself).closure_data.as(Pointer(StaticList))
  end

  def self.link(prev : StaticList*, _next : StaticList*)
    prev.value.next = _next
    _next.value.prev = prev
  end

  protected def self.insert_impl(new : StaticList*, prev : StaticList*, _next : StaticList*)
    link prev, new
    link new, _next
  end

  def init
    tmp = self_pointer
    typeof(self).link tmp, tmp
  end

  def append_to(list : StaticList*)
    typeof(self).insert_impl self_pointer, list.value.prev, list
  end

  def prepend_to(list : StaticList*)
    typeof(self).insert_impl self_pointer, list, list.value.next
  end

  def unlink
    typeof(self).link @prev, @next
  end

  def move_to_front(list : StaticList*)
    unlink
    prepend_to list
  end

  def move_to_back(list : StaticList*)
    unlink
    append_to list
  end

  def list_append_to(list : StaticList*)
    typeof(self).link list.value.prev, @next
    typeof(self).link @prev, list
    init
  end

  def list_prepend_to(list : StaticList*)
    typeof(self).link @prev, list.value.next
    typeof(self).link list, @next
    init
  end

  private def shift_internal
    unless empty?
      x = @next
      x.value.unlink
      x
    else
      yield
    end
  end

  def shift?
    shift_internal { nil }
  end

  private def pop_internal
    unless empty?
      x = @prev
      x.value.unlink
      x
    else
      yield
    end
  end

  def pop?
    pop_internal { nil }
  end

  def empty?
    @next == self_pointer
  end

  def each
    head = self_pointer
    it = @next

    while it != head
      yield it

      it = it.value.next
    end
  end
end
