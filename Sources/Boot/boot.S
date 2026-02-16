#define MULTIBOOT_MAGIC 0x1BADB002
#define MULTIBOOT_FLAGS (1 << 0) | (1 << 1) | (1 << 16)
#define MULTIBOOT_CHECKSUM -(MULTIBOOT_MAGIC + MULTIBOOT_FLAGS)

.section .boot, "ax"
.align 4
multiboot_header:
    .long MULTIBOOT_MAGIC
    .long MULTIBOOT_FLAGS
    .long MULTIBOOT_CHECKSUM
    .long 0x100000
    .long 0x100000
    .long 0
    .long 0
    .long 0x100020

.code32
.global _start
_start:
    cli
    # Save info pointer immediately
    mov %ebx, (mb_info_storage)

    mov $stack_top, %esp

    # Map 4GB
    mov $p4_table, %edi
    mov $24576, %ecx
    xor %eax, %eax
    rep stosb

    mov $p4_table, %edi
    mov $p3_table, %eax
    or $7, %eax
    mov %eax, (%edi)

    mov $p3_table, %edi
    mov $p2_table_base, %eax
    or $7, %eax
    mov %eax, 0(%edi)
    add $4096, %eax
    mov %eax, 8(%edi)
    add $4096, %eax
    mov %eax, 16(%edi)
    add $4096, %eax
    mov %eax, 24(%edi)

    mov $0, %ecx
.map_p2:
    mov %ecx, %eax
    mov $0x200000, %ebx
    mul %ebx
    or $0x87, %eax
    mov $p2_table_base, %edi
    mov %eax, (%edi, %ecx, 8)
    inc %ecx
    cmp $2048, %ecx
    jne .map_p2

    mov %cr4, %eax
    or $(1 << 5), %eax
    mov %eax, %cr4
    mov $0xC0000080, %ecx
    rdmsr
    or $(1 << 8), %eax
    wrmsr
    mov $p4_table, %eax
    mov %eax, %cr3
    mov %cr0, %eax
    or $(1 << 31), %eax
    mov %eax, %cr0

    lgdt gdt32_ptr
    ljmp $0x08, $realm64

.section .rodata
.align 8
gdt32:
    .quad 0
    .quad 0x00af9b000000ffff
gdt32_ptr:
    .word . - gdt32 - 1
    .long gdt32

.section .data
.align 4
mb_info_storage: .long 0

.code64
realm64:
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    
    mov $0x2BADB002, %edi
    mov (mb_info_storage), %esi
    .extern kmain
    call kmain
    hlt

.section .bss
.align 4096
p4_table: .skip 4096
p3_table: .skip 4096
p2_table_base: .skip 16384
stack_bottom: .skip 16384
.global stack_top
stack_top: