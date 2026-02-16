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

    # Zero all page tables
    mov $p4_table, %edi
    mov $(4096 + 4096 + 8*4096), %ecx   # p4 + p3 + 8 x p2 tables
    xor %eax, %eax
    rep stosb

    # PML4[0] -> p3_table (covers 0-512GB)
    mov $p4_table, %edi
    mov $p3_table, %eax
    or $7, %eax
    mov %eax, (%edi)
    mov %eax, 2040(%edi)

    # P3[0..7] -> p2 tables (covers 0-8GB, 1GB each)
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

    # Fill all 4096 P2 entries (8GB worth of 2MB pages)
    # Map p3_kasan to p4_table[27] (0xdffffc0000000000 -> 0x1B)
    mov $p3_kasan, %eax
    or $0x3, %eax
    mov $p4_table, %edi
    mov %eax, 216(%edi)

    # Also map for upper kernel addresses (shadow offset might shift wrap)
    # 0xffffffff80000000 >> 3 = 0x1ffffffff0000000
    # + 0xdffffc0000000000 = 0xfffffbf000000000 (PML4 index ~511)
    # For now, let's just ensure we map the upper range too if needed.
    # Actually, KASAN_SHADOW_OFFSET 0xdffffc0000000000 relies on the address being canonical.
    # Let's map p3_kasan to PML4[256] (0xffff800000000000) just in case
    mov %eax, 2048(%edi)

    # Map p2_kasan to p3_kasan[0]
    mov $p2_kasan, %eax
    or $0x3, %eax
    mov $p3_kasan, %edi
    mov %eax, (%edi)

    # Map 1GB of shadow memory (p2_kasan) to physical 0 (all good)
    # We cheat and map it to physical 0 for now (or a zero page if we had one)
    # Actually, we should map it to actual memory if we want to write to it.
    # For now, let's map it to the start of memory (dangerous if we write).
    # Better: Map to high memory we aren't using, e.g., 64MB+
    # Let's map 512 entries of p2_kasan to 0x4000000 (64MB)
    mov $0, %ecx
.map_kasan:
    mov %ecx, %eax
    shl $21, %eax           # 2MB increments
    add $0x4000000, %eax    # Start at 64MB
    or $0x83, %eax          # Present + RW + PS
    mov $p2_kasan, %edi
    mov %eax, (%edi, %ecx, 8)
    inc %ecx
    cmp $512, %ecx
    jne .map_kasan

    mov $0, %ecx
.map_p2:
    mov %ecx, %eax
    mov $0x200000, %ebx
    mul %ebx
    or $0x87, %eax           # Present + RW + User + PS (2MB page)
    mov $p2_table_base, %edi
    mov %eax, (%edi, %ecx, 8)
    # Upper 32 bits for addresses > 4GB
    mov %ecx, %eax
    shr $11, %eax             # eax = ecx * 2MB >> 32 = ecx >> 11
    mov $p2_table_base, %edi
    lea 4(%edi, %ecx, 8), %edi
    mov %eax, (%edi)
    mov %eax, 2040(%edi)
    inc %ecx
    cmp $4096, %ecx           # 4096 entries * 2MB = 8GB
    jne .map_p2

    mov %cr4, %eax
    or $(1 << 5), %eax
    mov %eax, %cr4
    mov $0xC0000080, %ecx
    rdmsr
    or $(1 << 8), %eax
    wrmsr
    # Enable SSE and FPU
    # CR0: Clear EM (2), set MP (1)
    mov %cr0, %eax
    and $(~(1 << 2)), %eax
    or $(1 << 1), %eax
    mov %eax, %cr0
    # CR4: Set OSFXSR (9) and OSXMMEXCPT (10)
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
p2_table_base: .skip 32768    # 8 x 4096 = 32KB for 8 L2 tables
stack_bottom: .skip 65536
.align 4096
p3_kasan: .skip 4096
p2_kasan: .skip 4096
.global stack_top
stack_top: