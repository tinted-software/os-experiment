.section __TEXT,__text
.globl _main
_main:
    mov $0x2000004, %eax
    mov $1, %edi
    lea msg(%rip), %rsi
    mov $14, %edx
    syscall
    mov $0x2000001, %eax
    xor %edi, %edi
    syscall

.section __DATA,__data
msg: .ascii "Hello Mach-O!\n"
