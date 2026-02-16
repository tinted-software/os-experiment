#include <stddef.h>
#include <stdint.h>

void serial_putc(uint8_t c);
void setup_gdt_tss(uint64_t kstack);
void setup_syscall_msrs(void);
void jump_to_user(uint64_t rip, uint64_t rsp);
void asm_hlt(void);
uint32_t pci_config_read(uint8_t b, uint8_t s, uint8_t f, uint8_t o);
void* memcpy(void* dest, const void* src, size_t n);
uint64_t get_stack_top(void);
extern uint8_t stack_top;
