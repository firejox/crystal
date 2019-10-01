require "crystal/spin_lock"
require "static_list"

# :nodoc:
class Thread
  # :nodoc:
  #
  # Thread-safe doubly linked list of `T` objects that must implement
  # `#previous : T?` and `#next : T?` methods.
  class LinkedList
    def initialize
      @mutex = Crystal::SpinLock.new
      @list = uninitialized StaticList
      @list.init
    end

    # Iterates the list without acquiring the lock, to avoid a deadlock in
    # stop-the-world situations, where a paused thread could have acquired the
    # lock to push/delete a node, while still being "safe" to iterate (but only
    # during a stop-the-world).
    def unsafe_each : Nil
      @list.each do |node|
        yield node
      end
    end

    # Appends a node to the tail of the list. The operation is thread-safe.
    #
    # There are no guarantees that a node being pushed will be iterated by
    # `#unsafe_each` until the method has returned.
    def push(node : StaticList*) : Nil
      @mutex.sync { node.value.append_to pointerof(@list) }
    end

    # Removes a node from the list. The operation is thread-safe.
    #
    # There are no guarantees that a node being deleted won't be iterated by
    # `#unsafe_each` until the method has returned.
    def delete(node : StaticList*) : Nil
      @mutex.sync { node.value.unlink }
    end
  end
end
