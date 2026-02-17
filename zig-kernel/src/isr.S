.section .text

.extern exception_handler

.macro ISR_NOERR n
.global isr_stub_\n
isr_stub_\n:
    pushq $0
    pushq $\n
    jmp isr_common
.endm

.macro ISR_ERR n
.global isr_stub_\n
isr_stub_\n:
    pushq $\n
    jmp isr_common
.endm

isr_common:
    /* Check if we were in user mode (CS & 3 != 0) */
    testq $3, 24(%rsp)
    jz 1f
    swapgs
1:
    push %rdi
    push %rsi
    push %rdx
    push %rcx
    push %r8
    push %r9
    push %r10
    push %r11
    
    /* Arguments for exception_handler(vector, error, rip, cs, rflags, rsp, ss) */
    /* vector = 64(%rsp) */
    /* error = 72(%rsp) */
    /* rip = 80(%rsp) */
    /* cs = 88(%rsp) */
    /* rflags = 96(%rsp) */
    /* rsp = 104(%rsp) */
    /* ss = 112(%rsp) */
    
    mov 64(%rsp), %rdi
    mov 72(%rsp), %rsi
    mov 80(%rsp), %rdx
    mov 88(%rsp), %rcx
    mov 96(%rsp), %r8
    mov 104(%rsp), %r9
    
    /* We need a 7th argument (ss), which goes on the stack in x86_64 calling convention? */
    /* Actually, sysV AMD64 uses RDI, RSI, RDX, RCX, R8, R9 for first 6 args. */
    /* 7th arg goes on stack. */
    push 112+8(%rsp) /* ss (offset shifted by push) */
    
    call exception_handler
    
    add $8, %rsp /* pop 7th arg */
    
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rcx
    pop %rdx
    pop %rsi
    pop %rdi
    
    add $16, %rsp /* pop vector and error code */
    
    /* Check again if we are returning to user mode */
    testq $3, 8(%rsp)
    jz 2f
    swapgs
2:
    iretq

.global load_gdt
load_gdt:
    lgdt (%rdi)
    ret

.global load_idt
load_idt:
    lidt (%rdi)
    ret

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_NOERR 8
ISR_NOERR 9
ISR_ERR 10
ISR_ERR 11
ISR_ERR 12
ISR_ERR 13
ISR_ERR 14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR 17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20

.global irq_stub_generic
irq_stub_generic:
    pushq $0
    pushq $255
    jmp isr_common
