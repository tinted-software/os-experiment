#include <stddef.h>
#include <stdint.h>

void outb(uint16_t p, uint8_t v) { __asm__ volatile("outb %0, %1" : : "a"(v), "dN"(p)); }
uint8_t inb(uint16_t p) { uint8_t v; __asm__ volatile("inb %1, %0" : "=a"(v) : "dN"(p)); return v; }

void serial_putc(uint8_t c) {
    while (!(inb(0x3f8 + 5) & 0x20));
    outb(0x3f8, c);
}

void serial_print(const char *s) {
    while (*s) serial_putc(*s++);
}

void *memset(void *s, int c, size_t n) {
    unsigned char *p = s; while (n--) *p++ = (unsigned char)c; return s;
}
void *memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = dest; const unsigned char *s = src;
    while (n--) *d++ = *s++; return dest;
}
void *memmove(void *dest, const void *src, size_t n) {
    unsigned char *d = dest; const unsigned char *s = src;
    if (d < s) while (n--) *d++ = *s++;
    else { d += n; s += n; while (n--) *(--d) = *(--s); }
    return dest;
}
int putchar(int c) { serial_putc((uint8_t)c); return c; }
extern uint8_t stack_top;
uint64_t get_stack_top(void) { return (uintptr_t)&stack_top; }

// 64-bit TSS Structure
struct tss_entry {
    uint32_t res0;
    uint64_t rsp0;
    uint64_t rsp1;
    uint64_t rsp2;
    uint64_t res1;
    uint64_t ist[7];
    uint64_t res2;
    uint16_t res3;
    uint16_t iopb;
} __attribute__((packed, aligned(16))) tss;

// 64-bit GDT with 16-byte TSS descriptor
uint64_t gdt[] __attribute__((aligned(16))) = {
    0,                  // 0x00: Null
    0x00af9b000000ffff, // 0x08: KCode
    0x00cf93000000ffff, // 0x10: KData
    0x00affb000000ffff, // 0x18: UCode32
    0x00cff3000000ffff, // 0x20: UData
    0x00affa000000ffff, // 0x28: UCode64
    0, 0                // 0x30: TSS (16 bytes)
};

void setup_gdt_tss(uint64_t kstack) {
    serial_print("GDT re-init\n");
    memset(&tss, 0, sizeof(tss));
    tss.rsp0 = kstack;
    tss.iopb = sizeof(tss);

    uint64_t base = (uintptr_t)&tss;
    uint32_t limit = sizeof(tss) - 1;

    // TSS Descriptor Lower 8 bytes
    gdt[6] = (limit & 0xffff) |
             ((base & 0xffff) << 16) |
             ((base & 0xff0000) << 16) |
             (0x89ULL << 40) |
             (((base & 0xff000000) >> 24) << 56);
    
    // TSS Descriptor Upper 8 bytes
    gdt[7] = (base >> 32);

    struct {
        uint16_t limit;
        uint64_t base;
    } __attribute__((packed)) gdtr = { sizeof(gdt) - 1, (uintptr_t)gdt };

    __asm__ volatile("lgdt %0" : : "m"(gdtr));
    serial_print("GDT loaded\n");

    __asm__ volatile("ltr %%ax" : : "a"((uint16_t)0x30));
    serial_print("TSS loaded\n");
}

extern uint64_t handle_syscall(uint64_t n, uint64_t a1, uint64_t a2, uint64_t a3);
__asm__(
    ".global syscall_entry\n"
    "syscall_entry:\n"
    "swapgs\n"
    "mov %rsp, %gs:12\n" // Save user RSP in tss.rsp1
    "mov %gs:4, %rsp\n"  // Load tss.rsp0
    "push %r11\n"        // Save RFLAGS
    "push %rcx\n"        // Save RIP
    "mov %rdx, %rcx\n"
    "mov %rsi, %rdx\n"
    "mov %rdi, %rsi\n"
    "mov %rax, %rdi\n"
    "call handle_syscall\n"
    "pop %rcx\n"
    "pop %r11\n"
    "mov %gs:12, %rsp\n" // Restore user RSP
    "swapgs\n"
    "sysretq\n"
);

void setup_syscall_msrs() {
    extern void syscall_entry();
    uintptr_t e = (uintptr_t)syscall_entry;
    __asm__ volatile("wrmsr" : : "c"(0xC0000082), "a"((uint32_t)e), "d"((uint32_t)(e >> 32)));
    // STAR: CS=0x08, SS=0x10, UserCS=0x1B, UserSS=0x23
    uint64_t star = ((uint64_t)0x18 << 48) | ((uint64_t)0x08 << 32);
    __asm__ volatile("wrmsr" : : "c"(0xC0000081), "a"(0), "d"((uint32_t)(star >> 32)));
    __asm__ volatile("wrmsr" : : "c"(0xC0000084), "a"(0x200), "d"(0));
    
    // Set KERNEL_GS_BASE for swapgs
    uintptr_t base = (uintptr_t)&tss;
    __asm__ volatile("wrmsr" : : "c"(0xC0000102), "a"((uint32_t)base), "d"((uint32_t)(base >> 32)));
    
    uint32_t l, h; __asm__ volatile("rdmsr" : "=a"(l), "=d"(h) : "c"(0xC0000080));
    __asm__ volatile("wrmsr" : : "c"(0xC0000080), "a"(l|1), "d"(h));
}

void jump_to_user(uint64_t rip, uint64_t rsp) {
    serial_print("Jump\n");
    __asm__ volatile(
        "cli\n"
        "mov $0x23, %%ax\n"
        "mov %%ax, %%ds\n"
        "mov %%ax, %%es\n"
        "pushq $0x23\n"
        "pushq %1\n"
        "pushq $0x002\n"
        "pushq $0x2B\n"
        "pushq %0\n"
        "iretq"
        : : "r"(rip), "r"(rsp) : "ax", "memory"
    );
}

void asm_hlt() { __asm__ volatile("hlt"); }
uint32_t pci_config_read(uint8_t b, uint8_t s, uint8_t f, uint8_t o) {
    uint32_t a = (1U<<31)|(b<<16)|(s<<11)|(f<<8)|(o&0xfc);
    __asm__ volatile("outl %0, %1" : : "a"(a), "dN"((uint16_t)0xCF8));
    uint32_t r; __asm__ volatile("inl %1, %0" : "=a"(r) : "dN"((uint16_t)0xCFC)); return r;
}
