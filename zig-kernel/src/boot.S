#define MULTIBOOT2_MAGIC 0xe85250d6
#define MULTIBOOT2_ARCH  0

#define MULTIBOOT_MAGIC 0x1BADB002
#define MULTIBOOT_FLAGS 0x3
#define MULTIBOOT_CHECKSUM -(MULTIBOOT_MAGIC + MULTIBOOT_FLAGS)

.section .multiboot, "ax"
.balign 8

/* Multiboot 1 Header */
.long MULTIBOOT_MAGIC
.long MULTIBOOT_FLAGS
.long MULTIBOOT_CHECKSUM

/* Multiboot 2 Header */
.balign 8
multiboot_header:
    .long MULTIBOOT2_MAGIC
    .long MULTIBOOT2_ARCH
    .long (multiboot_header_end - multiboot_header)
    .long -(MULTIBOOT2_MAGIC + MULTIBOOT2_ARCH + (multiboot_header_end - multiboot_header))

    /* Address tag */
    .balign 8
    .short 2, 0
    .long 24
    .long multiboot_header
    .long 0x100000
    .long 0
    .long 0

    /* Entry address tag */
    .balign 8
    .short 3, 0
    .long 12
    .long _start

    /* Information request tag */
    .balign 8
    .short 1, 0
    .long 20
    .long 1, 2, 6

    /* End tag */
    .balign 8
    .short 0, 0
    .long 8
multiboot_header_end:

.code32
.global _start
_start:
    cli
    /* Save info pointer and magic */
    mov %eax, (mb_magic_storage)
    mov %ebx, (mb_info_storage)

    mov $stack_top, %esp

    /* Zero all page tables */
    mov $p4_table, %edi
    mov $(4096 + 4096 + 8*4096), %ecx   /* p4 + p3 + 8 x p2 tables */
    xor %eax, %eax
    rep stosb

    /* PML4[0] -> p3_table (covers 0-512GB) */
    mov $p4_table, %edi
    mov $p3_table, %eax
    or $7, %eax
    mov %eax, (%edi)
    mov %eax, 2040(%edi)

    /* P3[0..7] -> p2 tables (covers 0-8GB, 1GB each) */
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
    add $4096, %eax
    mov %eax, 32(%edi)
    add $4096, %eax
    mov %eax, 40(%edi)
    add $4096, %eax
    mov %eax, 48(%edi)
    add $4096, %eax
    mov %eax, 56(%edi)

    /* Fill all 4096 P2 entries (8GB worth of 2MB pages) */
    mov $0, %ecx
.map_p2:
    mov %ecx, %eax
    mov $0x200000, %ebx
    mul %ebx
    or $0x87, %eax           /* Present + RW + User + PS (2MB page) */
    mov $p2_table_base, %edi
    mov %eax, (%edi, %ecx, 8)
    /* Upper 32 bits for addresses > 4GB */
    mov %ecx, %eax
    shr $11, %eax             /* eax = ecx * 2MB >> 32 = ecx >> 11 */
    mov $p2_table_base, %edi
    lea 4(%edi, %ecx, 8), %edi
    mov %eax, (%edi)
    inc %ecx
    cmp $4096, %ecx           /* 4096 entries * 2MB = 8GB */
    jne .map_p2

    mov %cr4, %eax
    or $(1 << 5), %eax
    mov %eax, %cr4
    mov $0xC0000080, %ecx
    rdmsr
    or $(1 << 8), %eax
    wrmsr
    /* Enable SSE and FPU */
    mov %cr0, %eax
    and $(~(1 << 2)), %eax
    or $(1 << 1), %eax
    mov %eax, %cr0
    mov %cr4, %eax
    or $(3 << 9), %eax
    mov %eax, %cr4

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
mb_magic_storage: .long 0
mb_info_storage: .long 0

.code64
realm64:
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    
    mov (mb_magic_storage), %edi
    mov (mb_info_storage), %esi
    .extern kmain
    call kmain
    hlt

.section .bss
.align 4096
p4_table: .skip 4096
p3_table: .skip 4096
p2_table_base: .skip 32768    /* 8 x 4096 = 32KB for 8 L2 tables */
stack_bottom: .skip 65536
.global stack_top
stack_top: