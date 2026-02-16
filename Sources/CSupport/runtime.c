#include <stddef.h>
#include <stdint.h>

void outb(uint16_t p, uint8_t v) {
  __asm__ volatile("outb %0, %1" : : "a"(v), "dN"(p));
}
uint8_t inb(uint16_t p) {
  uint8_t v;
  __asm__ volatile("inb %1, %0" : "=a"(v) : "dN"(p));
  return v;
}

// Initialize COM1 serial port (0x3F8)
void serial_init(void) {
  outb(0x3F8 + 1, 0x00); // Disable interrupts
  outb(0x3F8 + 3, 0x80); // Enable DLAB (baud rate divisor)
  outb(0x3F8 + 0, 0x01); // Divisor lo: 115200 baud
  outb(0x3F8 + 1, 0x00); // Divisor hi
  outb(0x3F8 + 3, 0x03); // 8N1
  outb(0x3F8 + 2, 0xC7); // Enable FIFO, clear, 14-byte threshold
  outb(0x3F8 + 4, 0x0B); // IRQs enabled, RTS/DSR set
}

void serial_putc(uint8_t c) {
  while (!(inb(0x3f8 + 5) & 0x20))
    ;
  outb(0x3f8, c);
}

void serial_print(const char *s) {
  while (*s)
    serial_putc(*s++);
}

void *memset(void *s, int c, size_t n) {
  unsigned char *p = s;
  while (n--)
    *p++ = (unsigned char)c;
  return s;
}
void *memcpy(void *dest, const void *src, size_t n) {
  unsigned char *d = dest;
  const unsigned char *s = src;
  while (n--)
    *d++ = *s++;
  return dest;
}
void *memmove(void *dest, const void *src, size_t n) {
  unsigned char *d = dest;
  const unsigned char *s = src;
  if (d < s)
    while (n--)
      *d++ = *s++;
  else {
    d += n;
    s += n;
    while (n--)
      *(--d) = *(--s);
  }
  return dest;
}
int putchar(int c) {
  serial_putc((uint8_t)c);
  return c;
}
extern uint8_t stack_top;
uint64_t get_stack_top(void) { return (uintptr_t)&stack_top; }

// ========================= IDT =========================
struct idt_entry {
  uint16_t offset_lo;
  uint16_t selector;
  uint8_t ist;
  uint8_t type_attr;
  uint16_t offset_mid;
  uint32_t offset_hi;
  uint32_t reserved;
} __attribute__((packed));

struct idt_entry idt[256] __attribute__((aligned(16)));

void set_idt_gate(int n, uint64_t handler, uint8_t ist, uint8_t type) {
  idt[n].offset_lo = handler & 0xFFFF;
  idt[n].selector = 0x08; // kernel code segment
  idt[n].ist = ist;
  idt[n].type_attr = type;
  idt[n].offset_mid = (handler >> 16) & 0xFFFF;
  idt[n].offset_hi = (handler >> 32) & 0xFFFFFFFF;
  idt[n].reserved = 0;
}

static void print_hex64(uint64_t v) {
  char hex[] = "0123456789ABCDEF";
  for (int i = 60; i >= 0; i -= 4)
    serial_putc(hex[(v >> i) & 0xF]);
}

// Generic exception handler called from assembly stubs
void exception_handler(uint64_t vector, uint64_t error, uint64_t rip,
                       uint64_t cs, uint64_t rflags, uint64_t rsp,
                       uint64_t ss) {
  const char *names[] = {"#DE Divide Error",
                         "#DB Debug",
                         "NMI Interrupt",
                         "#BP Breakpoint",
                         "#OF Overflow",
                         "#BR BOUND Range Exceeded",
                         "#UD Invalid Opcode",
                         "#NM Device Not Available",
                         "#DF Double Fault",
                         "Coprocessor Segment Overrun",
                         "#TS Invalid TSS",
                         "#NP Segment Not Present",
                         "#SS Stack-Segment Fault",
                         "#GP General Protection Fault",
                         "#PF Page Fault",
                         "Reserved",
                         "#MF x87 FPU Floating-Point Error",
                         "#AC Alignment Check",
                         "#MC Machine Check",
                         "#XM SIMD Floating-Point Exception",
                         "#VE Virtualization Exception"};

  serial_print("\n=== EXCEPTION ===\n");
  if (vector < 21) {
    serial_print("  Name:   ");
    serial_print(names[vector]);
    serial_print("\n");
  } else {
    serial_print("  Vector: ");
    print_hex64(vector);
    serial_print("\n");
  }
  serial_print("  Error:  ");
  print_hex64(error);
  serial_print("\n  RIP:    0x");
  print_hex64(rip);
  serial_print("\n  CS:     0x");
  print_hex64(cs);
  serial_print("\n  RFLAGS: 0x");
  print_hex64(rflags);
  serial_print("\n  RSP:    0x");
  print_hex64(rsp);
  serial_print("\n  SS:     0x");
  print_hex64(ss);
  serial_print("\n");

  uint64_t cr2;
  __asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
  serial_print("  CR2:    0x");
  print_hex64(cr2);
  serial_print("\n");

  if (rip >= 0x1000) {
    serial_print("  Code at RIP: ");
    uint64_t *p = (uint64_t *)rip;
    print_hex64(*p);
    serial_print("\n");
  }

  if (vector == 14) {
    serial_print("  Fault:  ");
    if (error & 1)
      serial_print("protection ");
    else
      serial_print("not-present ");
    if (error & 2)
      serial_print("write ");
    else
      serial_print("read ");
    if (error & 4)
      serial_print("user ");
    else
      serial_print("supervisor ");
    serial_print("\n");
  }

  // Dump saved general registers (from isr_common stack)
  // At this point, exception_handler was called with saved regs on stack above
  // us. We can read the saved regs via inline asm or just dump what we have.
  // The ISR stub pushes: rdi, rsi, rdx, rcx, r8, r9, r10, r11
  // Those are at known offsets from our frame pointer.

  serial_print("  (exception_handler args: rdi(vector)=");
  print_hex64(vector);
  serial_print(" rsi(error)=");
  print_hex64(error);
  serial_print(")\n");

  while (1) {
    __asm__ volatile("hlt");
  }
}

// Exception stubs
#define ISR_NOERRCODE(n)                                                       \
  __asm__(".global isr_stub_" #n "\n"                                          \
          "isr_stub_" #n ":\n"                                                 \
          "pushq $0\n"                                                         \
          "pushq $" #n "\n"                                                    \
          "jmp isr_common\n");

#define ISR_ERRCODE(n)                                                         \
  __asm__(".global isr_stub_" #n "\n"                                          \
          "isr_stub_" #n ":\n"                                                 \
          "pushq $" #n "\n"                                                    \
          "jmp isr_common\n");

__asm__("isr_common:\n"
        "testq $3, 24(%rsp)\n"
        "jz 1f\n"
        "swapgs\n"
        "1:\n"
        "push %rdi\n"
        "push %rsi\n"
        "push %rdx\n"
        "push %rcx\n"
        "push %r8\n"
        "push %r9\n"
        "push %r10\n"
        "push %r11\n"
        "mov 64(%rsp), %rdi\n"
        "mov 72(%rsp), %rsi\n"
        "mov 80(%rsp), %rdx\n"
        "mov 88(%rsp), %rcx\n"
        "mov 96(%rsp), %r8\n"
        "mov 104(%rsp), %r9\n"
        "push 112(%rsp)\n"
        "call exception_handler\n"
        "add $8, %rsp\n"
        "pop %r11\n"
        "pop %r10\n"
        "pop %r9\n"
        "pop %r8\n"
        "pop %rcx\n"
        "pop %rdx\n"
        "pop %rsi\n"
        "pop %rdi\n"
        "add $16, %rsp\n"
        "testq $3, 8(%rsp)\n"
        "jz 2f\n"
        "swapgs\n"
        "2:\n"
        "iretq\n");

ISR_NOERRCODE(0)
ISR_NOERRCODE(1)
ISR_NOERRCODE(2)
ISR_NOERRCODE(3)
ISR_NOERRCODE(4)
ISR_NOERRCODE(5)
ISR_NOERRCODE(6)
ISR_NOERRCODE(7)
ISR_NOERRCODE(8)
ISR_NOERRCODE(9)
ISR_ERRCODE(10)
ISR_ERRCODE(11)
ISR_ERRCODE(12)
ISR_ERRCODE(13)
ISR_ERRCODE(14)
ISR_NOERRCODE(15)
ISR_NOERRCODE(16)
ISR_ERRCODE(17)
ISR_NOERRCODE(18)
ISR_NOERRCODE(19)
ISR_NOERRCODE(20)

// Also define a generic IRQ stub for testing
__asm__(".global irq_stub_generic\n"
        "irq_stub_generic:\n"
        "pushq $0\n"
        "pushq $255\n"
        "jmp isr_common\n");

extern void isr_stub_0(void);
extern void isr_stub_1(void);
extern void isr_stub_2(void);
extern void isr_stub_3(void);
extern void isr_stub_4(void);
extern void isr_stub_5(void);
extern void isr_stub_6(void);
extern void isr_stub_7(void);
extern void isr_stub_8(void);
extern void isr_stub_9(void);
extern void isr_stub_10(void);
extern void isr_stub_11(void);
extern void isr_stub_12(void);
extern void isr_stub_13(void);
extern void isr_stub_14(void);
extern void isr_stub_15(void);
extern void isr_stub_16(void);
extern void isr_stub_17(void);
extern void isr_stub_18(void);
extern void isr_stub_19(void);
extern void isr_stub_20(void);
extern void irq_stub_generic(void);

typedef void (*isr_func)(void);

void setup_idt(void) {
  memset(idt, 0, sizeof(idt));

  isr_func stubs[] = {isr_stub_0,  isr_stub_1,  isr_stub_2,  isr_stub_3,
                      isr_stub_4,  isr_stub_5,  isr_stub_6,  isr_stub_7,
                      isr_stub_8,  isr_stub_9,  isr_stub_10, isr_stub_11,
                      isr_stub_12, isr_stub_13, isr_stub_14, isr_stub_15,
                      isr_stub_16, isr_stub_17, isr_stub_18, isr_stub_19,
                      isr_stub_20};

  for (int i = 0; i < 21; i++) {
    set_idt_gate(i, (uint64_t)stubs[i], 0, 0x8E);
  }
  // Fill rest with generic stub to avoid #GP on unexpected interrupts
  for (int i = 21; i < 256; i++) {
    set_idt_gate(i, (uint64_t)irq_stub_generic, 0, 0x8E);
  }

  struct {
    uint16_t limit;
    uint64_t base;
  } __attribute__((packed)) idtr = {sizeof(idt) - 1, (uintptr_t)idt};

  __asm__ volatile("lidt %0" : : "m"(idtr));
  serial_print("IDT loaded\n");
}

void enable_fsgsbase(void) {
  uint32_t eax, ebx, ecx, edx;
  __asm__ volatile("cpuid"
                   : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
                   : "a"(7), "c"(0));
  if (ebx & 1) {
    uint64_t cr4;
    __asm__ volatile("mov %%cr4, %0" : "=r"(cr4));
    cr4 |= (1ULL << 16);
    __asm__ volatile("mov %0, %%cr4" : : "r"(cr4));
    serial_print("FSGSBASE enabled\n");
  }
}

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

uint64_t gdt[] __attribute__((aligned(16))) = {0,
                                               0x00af9b000000ffff,
                                               0x00cf93000000ffff,
                                               0x00affb000000ffff,
                                               0x00cff3000000ffff,
                                               0x00affa000000ffff,
                                               0,
                                               0};

void setup_gdt_tss(uint64_t kstack) {
  serial_print("GDT init with stack: 0x");
  print_hex64(kstack);
  serial_print("\n");
  memset(&tss, 0, sizeof(tss));
  tss.rsp0 = kstack;
  tss.iopb = sizeof(tss);

  uint64_t base = (uintptr_t)&tss;
  uint32_t limit = sizeof(tss) - 1;
  gdt[6] = (limit & 0xffff) | ((base & 0xffff) << 16) |
           ((base & 0xff0000) << 16) | (0x89ULL << 40) |
           (((base & 0xff000000) >> 24) << 56);
  gdt[7] = (base >> 32);

  struct {
    uint16_t limit;
    uint64_t base;
  } __attribute__((packed)) gdtr = {sizeof(gdt) - 1, (uintptr_t)gdt};
  __asm__ volatile("lgdt %0" : : "m"(gdtr));
  serial_print("GDT loaded\n");
  __asm__ volatile("ltr %%ax" : : "a"((uint16_t)0x30));
  serial_print("TSS loaded\n");
}

extern uint64_t handle_syscall(uint64_t n, uint64_t a1, uint64_t a2,
                               uint64_t a3, uint64_t a4, uint64_t a5,
                               uint64_t a6);
__asm__(".global syscall_entry\n"
        "syscall_entry:\n"
        "swapgs\n"
        "mov %rsp, %gs:12\n"
        "mov %gs:4, %rsp\n"
        "push %r11\n"
        "push %rcx\n"
        "push %rax\n"
        "push %rdi\n"
        "push %rsi\n"
        "push %rdx\n"
        "push %r10\n"
        "push %r8\n"
        "push %r9\n"
        "push %r12\n"
        "pop %r12\n"
        "sub $8, %rsp\n"
        "mov 8(%rsp), %r12\n"
        "mov %r12, (%rsp)\n"
        "mov 56(%rsp), %rdi\n"
        "mov 48(%rsp), %rsi\n"
        "mov 40(%rsp), %rdx\n"
        "mov 32(%rsp), %rcx\n"
        "mov 24(%rsp), %r8\n"
        "mov 16(%rsp), %r9\n"
        "call handle_syscall\n"
        "add $8, %rsp\n"
        "pop %r9\n"
        "pop %r8\n"
        "pop %r10\n"
        "pop %rdx\n"
        "pop %rsi\n"
        "pop %rdi\n"
        "add $8, %rsp\n"
        "pop %rcx\n"
        "pop %r11\n"
        "mov %gs:12, %rsp\n"
        "swapgs\n"
        "sysretq\n");

void setup_syscall_msrs() {
  extern void syscall_entry();
  uintptr_t e = (uintptr_t)syscall_entry;
  __asm__ volatile("wrmsr"
                   :
                   : "c"(0xC0000082), "a"((uint32_t)e),
                     "d"((uint32_t)(e >> 32)));
  uint32_t star_hi = (0x0018 << 16) | 0x0008;
  __asm__ volatile("wrmsr" : : "c"(0xC0000081), "a"(0), "d"(star_hi));
  __asm__ volatile("wrmsr" : : "c"(0xC0000084), "a"(0x200), "d"(0));
  uintptr_t base = (uintptr_t)&tss;
  __asm__ volatile("wrmsr"
                   :
                   : "c"(0xC0000102), "a"((uint32_t)base),
                     "d"((uint32_t)(base >> 32)));
  uint32_t l, h;
  __asm__ volatile("rdmsr" : "=a"(l), "=d"(h) : "c"(0xC0000080));
  __asm__ volatile("wrmsr" : : "c"(0xC0000080), "a"(l | 1), "d"(h));
  serial_print("Syscall MSRs configured\n");
}

void jump_to_user(uint64_t rip, uint64_t rsp) {
  serial_print("Jumping to user: RIP=0x");
  print_hex64(rip);
  serial_print(" RSP=0x");
  print_hex64(rsp);
  serial_print("\n");
  __asm__ volatile("cli\n"
                   "mov $0x23, %%ax\n"
                   "mov %%ax, %%ds\n"
                   "mov %%ax, %%es\n"
                   "pushq $0x23\n"
                   "pushq %1\n"
                   "pushq $0x002\n" // IF=0
                   "pushq $0x2B\n"
                   "pushq %0\n"
                   "iretq"
                   :
                   : "r"(rip), "r"(rsp)
                   : "ax", "memory");
}

void asm_hlt() { __asm__ volatile("hlt"); }
uint32_t pci_config_read(uint8_t b, uint8_t s, uint8_t f, uint8_t o) {
  uint32_t a = (1U << 31) | (b << 16) | (s << 11) | (f << 8) | (o & 0xfc);
  __asm__ volatile("outl %0, %1" : : "a"(a), "dN"((uint16_t)0xCF8));
  uint32_t r;
  __asm__ volatile("inl %1, %0" : "=a"(r) : "dN"((uint16_t)0xCFC));
  return r;
}
void pci_config_write(uint8_t b, uint8_t s, uint8_t f, uint8_t o, uint32_t v) {
  uint32_t a = (1U << 31) | (b << 16) | (s << 11) | (f << 8) | (o & 0xfc);
  __asm__ volatile("outl %0, %1" : : "a"(a), "dN"((uint16_t)0xCF8));
  __asm__ volatile("outl %0, %1" : : "a"(v), "dN"((uint16_t)0xCFC));
}
void asm_pause(void) { __asm__ volatile("pause"); }

extern void *kernel_alloc(size_t size, size_t align);
void *malloc(size_t size) { return kernel_alloc(size, 16); }
void free(void *ptr) {}
void *calloc(size_t nmemb, size_t size) {
  size_t total = nmemb * size;
  void *p = malloc(total);
  if (p)
    memset(p, 0, total);
  return p;
}
void *realloc(void *ptr, size_t size) {
  if (!ptr)
    return malloc(size);
  void *new_ptr = malloc(size);
  return new_ptr;
}
int posix_memalign(void **memptr, size_t alignment, size_t size) {
  *memptr = kernel_alloc(size, alignment);
  return 0;
}
void asm_volatile_barrier(void) { __asm__ volatile("" : : : "memory"); }
int memcmp(const void *s1, const void *s2, size_t n) {
  const unsigned char *p1 = s1, *p2 = s2;
  while (n--) {
    if (*p1 != *p2)
      return *p1 - *p2;
    p1++;
    p2++;
  }
  return 0;
}
double ceil(double x) {
  long i = (long)x;
  if (x == (double)i)
    return x;
  return x > 0 ? (double)(i + 1) : (double)i;
}
void arc4random_buf(void *buf, size_t nbytes) {
  unsigned char *p = buf;
  while (nbytes--)
    *p++ = 0;
}
void *_swift_stdlib_getNormData() { return 0; }
void *_swift_stdlib_getComposition() { return 0; }
void *_swift_stdlib_getDecompositionEntry() { return 0; }
const unsigned char _swift_stdlib_nfd_decompositions[1] = {0};
int _swift_stdlib_isExtendedPictographic(uint32_t s) { return 0; }
int _swift_stdlib_isInCB_Consonant(uint32_t s) { return 0; }
int _swift_stdlib_getGraphemeBreakProperty(uint32_t s) { return 0; }
uint64_t asm_get_cr3(void) {
  uint64_t cr3;
  __asm__ volatile("mov %%cr3, %0" : "=r"(cr3));
  return cr3;
}
void asm_set_cr3(uint64_t cr3) {
  __asm__ volatile("mov %0, %%cr3" : : "r"(cr3));
}
void asm_invlpg(void *addr) {
  __asm__ volatile("invlpg (%0)" : : "r"(addr) : "memory");
}

void asm_wrmsr(uint32_t msr, uint64_t v) {
  uint32_t l = v & 0xFFFFFFFF;
  uint32_t h = v >> 32;
  __asm__ volatile("wrmsr" : : "c"(msr), "a"(l), "d"(h));
}
