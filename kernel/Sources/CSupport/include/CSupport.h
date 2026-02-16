#include <stddef.h>
#include <stdint.h>

void serial_init(void);
void serial_putc(uint8_t c);
void setup_gdt_tss(uint64_t kstack);
void setup_syscall_msrs(void);
void setup_idt(void);
void enable_fsgsbase(void);
void jump_to_user(uint64_t rip, uint64_t rsp);
void asm_hlt(void);
uint32_t pci_config_read(uint8_t b, uint8_t s, uint8_t f, uint8_t o);
void *memcpy(void *dest, const void *src, size_t n);
void *memset(void *s, int c, size_t n);
void *memmove(void *dest, const void *src, size_t n);
uint64_t get_stack_top(void);
void pci_config_write(uint8_t b, uint8_t s, uint8_t f, uint8_t o, uint32_t v);
void asm_pause(void);
void asm_volatile_barrier(void);

struct cpio_newc_header {
  unsigned char c_magic[6];
  unsigned char c_ino[8];
  unsigned char c_mode[8];
  unsigned char c_uid[8];
  unsigned char c_gid[8];
  unsigned char c_nlink[8];
  unsigned char c_mtime[8];
  unsigned char c_filesize[8];
  unsigned char c_devmajor[8];
  unsigned char c_devminor[8];
  unsigned char c_rdevmajor[8];
  unsigned char c_rdevminor[8];
  unsigned char c_namesize[8];
  unsigned char c_check[8];
};

uint64_t asm_get_cr3(void);
void asm_set_cr3(uint64_t cr3);
void asm_invlpg(void *addr);
void asm_wrmsr(uint32_t msr, uint64_t v);
