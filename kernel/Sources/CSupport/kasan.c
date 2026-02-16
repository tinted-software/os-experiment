/*
 * kasan.c
 * Kernel Address Sanitizer Runtime
 *
 * Implements the __asan_load/store hooks emitted by the compiler.
 * Uses a shadow memory bitmap where each byte tracks the state of 8 bytes of
 * real memory. 0 = good, non-zero = poisoned.
 */

#include <stddef.h>
#include <stdint.h>

// KASAN Shadow Offset
// For x86_64, a common offset is 0xdffffc0000000000
// But we need to tailor this to our kernel memory map.
// Let's assume a simpler offset for now if we can, or just stick to the
// standard one if we map it high.
#define KASAN_SHADOW_OFFSET 0xdffffc0000000000ULL

static inline int8_t *kasan_mem_to_shadow(const void *addr) {
  return (int8_t *)((((uintptr_t)addr) >> 3) + KASAN_SHADOW_OFFSET);
}

void kasan_report(uintptr_t addr, size_t size, int is_write, uintptr_t ip);

// External kernel print helper
void serial_putc(char c);

void print_hex64(uint64_t val) {
  char hex[] = "0123456789ABCDEF";
  for (int i = 60; i >= 0; i -= 4) {
    serial_putc(hex[(val >> i) & 0xF]);
  }
}

void kasan_report(uintptr_t addr, size_t size, int is_write, uintptr_t ip) {
  char msg1[] = "\nKASAN: Use-after-free or out-of-bounds access\n";
  char *p = msg1;
  while (*p)
    serial_putc(*p++);

  char msg2[] = "Addr: ";
  p = msg2;
  while (*p)
    serial_putc(*p++);
  print_hex64(addr);

  char msg3[] = " IP: ";
  p = msg3;
  while (*p)
    serial_putc(*p++);
  print_hex64(ip);

  serial_putc('\n');
  while (1) {
    __asm__ volatile("hlt");
  }
}

void __asan_loadN_noabort(uintptr_t addr, size_t size) {
  int8_t *shadow = kasan_mem_to_shadow((void *)addr);
  int8_t val = *shadow;
  if (val != 0) {
    // Slow path check
    // If val > 0, strict check first k bytes
    if ((int8_t)((addr & 7) + size) >= val) {
      kasan_report(addr, size, 0, (uintptr_t)__builtin_return_address(0));
    }
  }
}

void __asan_storeN_noabort(uintptr_t addr, size_t size) {
  int8_t *shadow = kasan_mem_to_shadow((void *)addr);
  int8_t val = *shadow;
  if (val != 0) {
    if ((int8_t)((addr & 7) + size) >= val) {
      kasan_report(addr, size, 1, (uintptr_t)__builtin_return_address(0));
    }
  }
}

// Fixed size hooks
#define DEFINE_ASAN_LOAD_STORE(size)                                           \
  void __asan_load##size##_noabort(uintptr_t addr) {                           \
    __asan_loadN_noabort(addr, size);                                          \
  }                                                                            \
  void __asan_store##size##_noabort(uintptr_t addr) {                          \
    __asan_storeN_noabort(addr, size);                                         \
  }

DEFINE_ASAN_LOAD_STORE(1)
DEFINE_ASAN_LOAD_STORE(2)
DEFINE_ASAN_LOAD_STORE(4)
DEFINE_ASAN_LOAD_STORE(8)
DEFINE_ASAN_LOAD_STORE(16)

void __asan_handle_no_return(void) {}
void __asan_before_dynamic_init(const char *module_name) {}
void __asan_after_dynamic_init(void) {}

// Global init - called manually
void kasan_init(void) {
  // Map shadow memory... This needs to be done in boot.S really
  // Or we assume it's mapped.
  // We should at least unpoison the kernel code/data segments.
}
