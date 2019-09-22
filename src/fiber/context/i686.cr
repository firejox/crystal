{% skip_file unless flag?(:i686) %}

class Fiber
  # :nodoc:
  def makecontext(stack_ptr, fiber_main) : Nil
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
  def self.load_first_argument
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
end
