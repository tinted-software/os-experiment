.code64
.section .text
.global _start
_start:
    # write(1, msg, 13)
    mov $0x2000004, %rax
    mov $1, %rdi
    lea msg(%rip), %rsi
    mov $13, %rdx
    syscall

    # exit(0)
    mov $0x2000001, %rax
    xor %rdi, %rdi
    syscall

msg:
    .ascii "Hello User!\n"