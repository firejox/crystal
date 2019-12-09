{% skip_file unless flag?(:i686) %}

class Fiber
  # :nodoc:
  def makecontext(stack_ptr, fiber_main) : Nil
    # In IA32 (x86), the stack is required 16-byte alignment before `call`
    # instruction. Because `stack_ptr` is 16-byte alignment, we don't need to
    # reserve space on alignment. When returning to `entry function`, the
    # `ESP + 4` is 16 bytes alignment.
    #
    # Initial Stack
    #
    # +-----------------------+
    # |      fiber address    |
    # +-----------------------+
    # |     dummy address     |
    # +-----------------------+
    # |     entry function    |
    # +-----------------------+

    @context.stack_top = (stack_ptr - 2).as(Void*)
    @context.resumable = 1
    stack_ptr[0] = self.as(Void*)
    stack_ptr[-1] = Pointer(Void).null
    stack_ptr[-2] = fiber_main.pointer
  end

  @[NoInline]
  @[Naked]
  private def self.suspend_context(current_context, new_context, resume_func)
    # Stack Information
    #
    # |            :             |
    # +--------------------------+
    # |   callee-saved register  |
    # +--------------------------+
    # |       resume context     | <--- stack top
    # +--------------------------+

    asm("
      pushl %ebx        // push callee-saved registers on the stack
      pushl %ebp
      pushl %esi
      pushl $2          // push resume_context function_pointer
      movl %esp, 0($0)  // current_context.stack_top = %esp
      movl $$1, 4($0)   // current_context.resumable = 1

      movl $$0, 4($1)   // new_context.resumable = 0
      movl 0($1), %esp  // %esp = new_context.stack_top
      " :: "r"(current_context), "r"(new_context), "r"(resume_func))
  end

  @[NoInline]
  @[Naked]
  private def self.resume_context
    asm("
        popl %esi
        popl %ebp
        popl %ebx
        ")
  end

  # :nodoc:
  def self.swapcontext(current_context, new_context) : Nil
    suspend_context current_context, new_context, (->resume_context).pointer
  end

  @[NoInline]
  @[Naked]
  protected def self.load_first_argument
    # Stack requirement
    #
    # |            :           |
    # |            :           |
    # +------------------------+
    # |  target function addr  | ---> for pc register
    # +------------------------+
    # |     first argument     | ---> for edi register
    # +------------------------+

    asm("popl %edi")
  end

  # :nodoc:
  def add_gc_read_unlock_helper
    stack_ptr = @context.stack_top.as(Pointer(Void*))
    @context.stack_top = (stack_ptr - 1).as(Void*)
    stack_ptr[-1] = (->GC.unlock_read).pointer
  end

  protected def add_stack_release_helper(s : Void*)
    proc = ->(ptr : Void*) { Fiber.stack_pool.release(ptr) }
    stack_ptr = @context.stack_top.as(Pointer(Void*))
    @context.stack_top = (stack_ptr - 3).as(Void*)
    stack_ptr[-1] = s
    stack_ptr[-2] = (->Fiber.load_first_argument).pointer
    stack_ptr[-3] = proc.pointer
  end

  # :nodoc:
  def add_spin_unlock_helper(s : Crystal::SpinLock)
    proc = ->s.unlock
    stack_ptr = @context.stack_top.as(Pointer(Void*))
    @context.stack_top = (stack_ptr - 3).as(Void*)
    stack_ptr[-1] = s.as(Void*)
    stack_ptr[-2] = (->Fiber.load_first_argument).pointer
    stack_ptr[-3] = proc.pointer
  end

  # :nodoc:
  def add_select_actions_unlock_helper(s : Array(Channel::SelectAction))
    proc = ->{ s.each &.unlock }
    stack_ptr = @context.stack_top.as(Pointer(Void*))
    @context.stack_top = (stack_ptr - 3).as(Void*)
    stack_ptr[-1] = proc.closure_data
    stack_ptr[-2] = (->Fiber.load_first_argument).pointer
    stack_ptr[-3] = proc.pointer
  end
end
