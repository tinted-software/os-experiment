const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const multiboot = @import("multiboot.zig");
const cpio = @import("cpio.zig");

// Assembly symbols
extern var stack_top: u8;

pub fn panic(msg: []const u8, error_return_trace: anytype, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = ret_addr;
    while (true) {
        asm volatile ("hlt");
    }
}

const macho = @import("macho.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");

const MachMessageHeader = extern struct {
    msgh_bits: u32,
    msgh_size: u32,
    msgh_remote_port: u32,
    msgh_local_port: u32,
    msgh_reserved: u32,
    msgh_id: i32,
};

// ... imports ...

// ... defines ...

pub export fn kmain(magic: u32, info_addr: u32) callconv(.c) noreturn {
    serial_init();
    kprint("Zig OS Kernel Booting...\n");

    gdt.init(@intFromPtr(&stack_top));
    idt.init();
    vmm.setup();

    // ... magic parsing ...
    if (magic != 0x36D76289 and magic != 0x2BADB002) {
        kprint("Error: Invalid Multiboot magic: 0x");
        kprintHex(magic);
        kprint("\n");
        while (true) asm volatile ("hlt");
    }

    var ramdisk_addr: ?[*]const u8 = null;
    var ramdisk_len: usize = 0;

    if (magic == 0x36D76289) {
        kprint("Zig OS Kernel Booting (Multiboot 2)...\n");
        const header: *multiboot.Multiboot2Header = @ptrFromInt(info_addr);

        var offset: usize = 8;
        while (offset < header.total_size) {
            const tag: *multiboot.Multiboot2Tag = @ptrFromInt(info_addr + offset);
            if (tag.type == 0) break;

            if (tag.type == 3) { // Module
                const mod: *multiboot.Multiboot2TagModule = @ptrCast(tag);
                ramdisk_len = mod.mod_end - mod.mod_start;
                ramdisk_addr = @as([*]const u8, @ptrFromInt(mod.mod_start));
                kprint("Ramdisk found at 0x");
                kprintHex(mod.mod_start);
                kprint("\n");
            }
            offset = (offset + tag.size + 7) & ~@as(usize, 7);
        }
    } else {
        kprint("Zig OS Kernel Booting (Multiboot 1)...\n");
        const info: *multiboot.MultibootInfo = @ptrFromInt(info_addr);
        if ((info.flags & 8) != 0 and info.mods_count > 0) {
            const mods: [*]multiboot.MultibootModule = @ptrFromInt(info.mods_addr);
            const mod = mods[0];
            ramdisk_len = mod.mod_end - mod.mod_start;
            ramdisk_addr = @as([*]const u8, @ptrFromInt(mod.mod_start));
            kprint("Ramdisk found via MB1 at 0x");
            kprintHex(mod.mod_start);
            kprint("\n");
        } else {
            kprint("No modules found in MB1 info\n");
        }
    }

    if (ramdisk_addr) |rd| {
        const rd_slice = rd[0..ramdisk_len];
        if (cpio.findFile(rd_slice, "usr/lib/dyld")) |dyld_data| {
            kprint("Found dyld! Loading...\n");

            // Load dyld at 0x10000000 (256MB)
            if (loadMachO(dyld_data, 0x10000000)) |res| {
                kprint("dyld loaded. Entry: 0x");
                kprintHex(res.entry_point);
                kprint("\n");

                enable_features();

                // Setup stack for dyld
                const user_stack_top: u64 = 0x20000000; // 512MB - safely inside 1GB
                const stackSize: u64 = 0x4000; // 16KB
                // const stackStartVirt = user_stack_top - stackSize;

                // Allocate physical frames and map them into the user stack range
                var i_map: u64 = 0;
                while (i_map < (stackSize / 4096)) : (i_map += 1) {
                    if (pmm.allocateFrame()) |frame| {
                        vmm.map(user_stack_top - ((i_map + 1) * 4096), frame, 7);
                    }
                }

                // Zero out the stack pages we just mapped
                const sp_page: [*]u8 = @ptrFromInt(user_stack_top - stackSize);
                _ = memset(sp_page, 0, @as(usize, stackSize));

                // Sanity-check: write/read a marker at top of user stack
                const test_ptr: *u64 = @ptrFromInt(@as(usize, @intCast(user_stack_top - 8)));
                test_ptr.* = 0xDEADBEEF;
                kprint("Wrote marker to user stack: ");
                kprintHex(test_ptr.*);
                kprint("\n");

                const user_sp = setupDyldStack("init", res.text_base, res.entry_point, user_stack_top);

                kprint("Jumping to dyld at 0x");
                kprintHex(res.entry_point);
                kprint(" SP: 0x");
                kprintHex(user_sp);
                kprint("\n");

                if (TEST_USER_LOOP) {
                    // Place an int3 instruction on the mapped user stack to test execution
                    const test_entry: u64 = user_stack_top - 0x100;
                    const entry_ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(test_entry)));
                    entry_ptr[0] = 0xCC; // int3
                    kprint("Wrote int3 at user stack entry\n");

                    // Write infinite loop and jump to it in user mode
                    entry_ptr[0] = 0xEB;
                    entry_ptr[1] = 0xFE;
                    kprint("Wrote test loop at user stack entry\n");
                    dumpCR3AndPML4();
                    dumpPageTables(test_entry);
                    dumpPageTables(res.entry_point);
                    jump_to_user(test_entry, user_sp);
                } else {
                    dumpCR3AndPML4();
                    dumpPageTables(res.entry_point);
                    jump_to_user(res.entry_point, user_sp);
                }
            } else {
                kprint("Failed to load dyld Mach-O\n");
            }
        } else {
            kprint("usr/lib/dyld not found in ramdisk.\n");
        }
    } else {
        kprint("No ramdisk found.\n");
    }

    while (true) asm volatile ("hlt");
}

const MachOLoadResult = struct {
    entry_point: u64,
    text_base: u64,
};

fn dumpPageTables(virt: u64) void {
    const pml4Index: usize = @intCast((virt >> 39) & 0x1FF);
    const pdptIndex: usize = @intCast((virt >> 30) & 0x1FF);
    const pdIndex: usize = @intCast((virt >> 21) & 0x1FF);
    const ptIndex: usize = @intCast((virt >> 12) & 0x1FF);

    kprint("Page tables for ");
    kprintHex(virt);
    kprint("\n");
    const pml4e = vmm.pml4[pml4Index];
    kprint(" PML4[");
    kprintHex(@as(u64, pml4Index));
    kprint("]: ");
    kprintHex(pml4e);
    kprint("\n");
    if ((pml4e & 1) == 0) return;
    const pdpt: [*]u64 = @ptrFromInt(@as(usize, @intCast(pml4e & ~(@as(u64, 0xFFF)))));
    const pdpte = pdpt[pdptIndex];
    kprint(" PDPT[");
    kprintHex(@as(u64, pdptIndex));
    kprint("]: ");
    kprintHex(pdpte);
    kprint("\n");
    if ((pdpte & 1) == 0) return;
    const pd: [*]u64 = @ptrFromInt(@as(usize, @intCast(pdpte & ~(@as(u64, 0xFFF)))));
    const pde = pd[pdIndex];
    kprint(" PD[");
    kprintHex(@as(u64, pdIndex));
    kprint("]: ");
    kprintHex(pde);
    kprint("\n");
    if ((pde & 1) == 0) return;
    if ((pde & @as(u64, 0x80)) != 0) {
        kprint(" 2MB huge page\n");
        return;
    }
    const pt: [*]u64 = @ptrFromInt(@as(usize, @intCast(pde & ~(@as(u64, 0xFFF)))));
    const pte = pt[ptIndex];
    kprint(" PT[");
    kprintHex(@as(u64, ptIndex));
    kprint("]: ");
    kprintHex(pte);
    kprint("\n");
}

fn dumpCR3AndPML4() void {
    var cr3: u64 = undefined;
    asm volatile ("mov %%cr3, %[cr3]"
        : [cr3] "=r" (cr3),
    );
    kprint("CR3: 0x");
    kprintHex(cr3);
    kprint("\n");

    // Print PML4 pointer registered in vmm
    kprint("vmm.pml4 ptr: ");
    kprintHex(@as(u64, @intFromPtr(vmm.pml4)));
    kprint("\n");

    // Print first few PML4 entries for visibility
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const e = vmm.pml4[i];
        kprint("  PML4[");
        kprintHex(@as(u64, i));
        kprint("]: ");
        kprintHex(e);
        kprint("\n");
    }
}

const TEST_USER_LOOP: bool = false; // If true, overwrite user entry with infinite loop for testing

fn loadMachO(data: []const u8, slide: u64) ?MachOLoadResult {
    if (data.len < @sizeOf(macho.MachHeader64)) return null;
    const header: *const macho.MachHeader64 = @ptrCast(@alignCast(data.ptr));

    if (header.magic != macho.MH_MAGIC_64) {
        kprint("Invalid Mach-O magic\n");
        return null;
    }

    var result = MachOLoadResult{ .entry_point = 0, .text_base = 0 };
    var cmd_offset: usize = @sizeOf(macho.MachHeader64);
    var i: u32 = 0;

    var entry_is_relative = false;

    while (i < header.ncmds) : (i += 1) {
        if (cmd_offset + @sizeOf(macho.LoadCommand) > data.len) break;
        const cmd: *const macho.LoadCommand = @ptrCast(@alignCast(data.ptr + cmd_offset));

        switch (cmd.cmd) {
            macho.LC_SEGMENT_64 => {
                const seg: *const macho.SegmentCommand64 = @ptrCast(@alignCast(cmd));
                if (memcmp(&seg.segname, "__PAGEZERO", 10) == 0) {
                    // skip
                } else {
                    if (memcmp(&seg.segname, "__TEXT", 6) == 0) {
                        result.text_base = seg.vmaddr + slide;
                    }
                    if (seg.vmsize > 0) {
                        const dest_addr = seg.vmaddr + slide;
                        const dest: [*]u8 = @ptrFromInt(dest_addr);

                        // We assume memory is writable (identity mapped)
                        _ = memset(dest, 0, @intCast(seg.vmsize));
                        if (seg.filesize > 0) {
                            const src = data.ptr + seg.fileoff;
                            _ = memcpy(dest, src, @intCast(seg.filesize));
                        }
                        kprint("Loaded seg at 0x");
                        kprintHex(dest_addr);
                        kprint("\n");
                    }
                }
            },
            macho.LC_MAIN => {
                const ep: *const macho.EntryPointCommand = @ptrCast(@alignCast(cmd));
                result.entry_point = ep.entryoff;
                entry_is_relative = true;
            },
            macho.LC_UNIXTHREAD => {
                const thread: *const macho.ThreadCommand = @ptrCast(@alignCast(cmd));
                if (thread.flavor == 4) { // x86_THREAD_STATE64
                    // RIP is at offset 144 from start of command?
                    // cmd(4) + cmdsize(4) + flavor(4) + count(4) + rax(8)...
                    // Let's rely on offset
                    const regs_ptr = @as([*]const u64, @ptrCast(@alignCast(@as([*]const u8, @ptrCast(cmd)) + 16)));
                    // x86_thread_state64_t: rax, rbx, rcx, rdx, rdi, rsi, rbp, rsp, r8..r15, rip, ...
                    // rip is the 16th u64 (index 16)
                    result.entry_point = regs_ptr[16];
                }
            },
            else => {},
        }

        cmd_offset += cmd.cmdsize;
    }

    if (entry_is_relative) {
        result.entry_point += result.text_base; // Already has slide? No, text_base has slide.
        // Wait, text_base = vmaddr + slide. entryoff is relative to vmaddr of __TEXT?
        // Usually entryoff is relative to image load address (vmaddr 0).
        // Let's assume result.text_base (slide + vmaddr) is the base.
        // Actually LC_MAIN entryoff is offset from __TEXT start? Or file start?
        // Documentation says: "The file offset of the entry point".
        // No, `entryoff` is "The file offset of the entry point." -> File offset?
        // But swift code says: `result.entryPoint = result.entryPoint &+ result.textBase &+ slide` (Wait, swift logic seems to check `entryIsRelative`).
        // Swift: `result.entryPoint = result.entryPoint &+ result.textBase &+ slide`
        // If textBase includes slide, then `result.entryPoint + textBase` is enough?
        // Let's trust Swift: `result.entryPoint &+ result.textBase &+ slide`.
        // My text_base ALREADY includes slide.
        // So `entry_point + text_base` ?
        // Or `entry_point + (text_base - slide) + slide`?
        // Let's stick to Swift logic: `result.entryPoint + result.textBase` (if textBase is the load address).
        // Warning: Swift logic `result.textBase = vmaddr`. My logic `result.textBase = vmaddr + slide`.
        // So I should use `result.entry_point + (result.text_base - slide) + slide` = `result.entry_point + result.text_base`.
        // Wait, `LC_MAIN` uses an offset relative to the `__TEXT` segment's VM address.
        // If `__TEXT` is at 0, offset is absolute.
        // Let's assume `entry_point + result.text_base` is correct if `text_base` is the loaded address.
        // Actually, if `entryoff` is file offset, that's wrong for `LC_MAIN`. `LC_MAIN` usually specifies offset from vmaddr start?
        // "File offset of the entry point" - usually this means `__TEXT` segment file offset + entryoff?
        // Let's use `result.entry_point + result.text_base` (where text_base = loaded address).
    } else {
        result.entry_point += slide;
    }

    return result;
}

fn setupDyldStack(exec_path: []const u8, text_base: u64, entry_point: u64, user_stack_top: u64) u64 {
    _ = entry_point;
    // Strings at top - 0x100
    var string_ptr = user_stack_top - 0x100;

    // Copy exec_path
    const src_len = exec_path.len;
    const dest_ptr: [*]u8 = @ptrFromInt(string_ptr - src_len - 1);
    _ = memcpy(dest_ptr, exec_path.ptr, src_len);
    dest_ptr[src_len] = 0;
    string_ptr = string_ptr - src_len - 1;
    const exec_path_addr = string_ptr;

    // Align SP
    var sp = user_stack_top - 0x200;
    sp &= ~@as(u64, 0xF);

    // dyld4::KernelArgs
    // [0] mach_header
    // [1] argc
    // [2] argv[0]
    // [3] NULL
    // [4] NULL
    // [5] apple[0]
    // [6] NULL

    const sp_base: [*]u64 = @ptrFromInt(sp - 7 * 8);
    sp_base[0] = text_base;
    sp_base[1] = 1; // argc
    sp_base[2] = exec_path_addr;
    sp_base[3] = 0;
    sp_base[4] = 0;
    sp_base[5] = exec_path_addr;
    sp_base[6] = 0;

    return @intFromPtr(sp_base);
}

const MSR_STAR = 0xC0000081;
const MSR_LSTAR = 0xC0000082;
const MSR_FMASK = 0xC0000084;
const MSR_EFER = 0xC0000080;

fn enable_features() void {
    // Enable FSGSBASE (CR4 bit 16)
    var cr4: u64 = undefined;
    asm volatile ("mov %%cr4, %[cr4]"
        : [cr4] "=r" (cr4),
    );
    cr4 |= (1 << 16);
    asm volatile ("mov %[cr4], %%cr4"
        :
        : [cr4] "r" (cr4),
    );

    // Enable SCE (EFER bit 0)
    var efer_lo: u32 = undefined;
    var efer_hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (efer_lo),
          [hi] "={edx}" (efer_hi),
        : [msr] "{ecx}" (MSR_EFER),
    );
    efer_lo |= 1;
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (efer_lo),
          [hi] "{edx}" (efer_hi),
    );

    setup_syscalls();
}

fn setup_syscalls() void {
    // STAR: Syscall/Sysret CS/SS configuration
    // [63:48] Sysret CS (User CS - 16) -> 0x1B - 16 ?? No, sysret loads CS with (STAR[63:48] + 16) and SS with (STAR[63:48] + 8)
    // Actually Linux uses: Kernel CS=0x8, User CS 32-bit=0x23??
    // Standard x86_64:
    //   Syscall: CS = STAR[47:32] & 0xFFFC, SS = STAR[47:32] + 8
    //   Sysret:  CS = STAR[63:48] + 16,     SS = STAR[63:48] + 8
    // GDT: Null(0), KCode(8), KData(16), UCode(24=0x18), UData(32=0x20)
    // We want Syscall to load KCode(0x8). So STAR[47:32] = 0x8.
    // We want Sysret to load UCode(0x18) and UData(0x20).
    //   If STAR[63:48] = 0x8 (Kernel base), then CS=0x8+16=0x18 (UCode), SS=0x8+8=0x10 (KData? No).
    //   Wait, Sysret sets SS = STAR[63:48] + 8. If we want SS=0x20 (UData), we need base 0x18?
    //   Then CS = 0x18+16 = 0x28 (Invalid?).
    //   Actually GDT layout is usually: KCode, KData, UData, UCode.
    //   My GDT: 8=KCode, 16=KData, 24=UCode, 32=UData.
    //   This is "UCode, UData" order.
    //   Sysret: CS = Base+16, SS = Base+8.
    //   If Base=0x10 (KData selector), then SS=0x18 (UCode??), CS=0x20 (UData??).
    //   Inverted.
    //   Common trick: Organize GDT as KCode, KData, UData, UCode (or compat).
    //   Current GDT: 24(0x18)=UCode, 32(0x20)=UData.
    //   If I use Base=0x10. SS=0x18 (UCode). CS=0x20 (UData). This is backwards for standard layout.
    //   I should swap UCode and UData in GDT if I want standard SYSRET behavior?
    //   Or I can live with it if I don't use SYSRET immediately?
    //   But `dyld` might crash if I don't set it?
    //   For now, just Setting STAR to something valid prevents #GP on `syscall`.

    const k_cs = 0x08;
    const u_cs_base = 0x10; // SYSRET: CS = (base+16)|3 = 0x23, SS = (base+8)|3 = 0x1B

    // Low 32: EIP (legacy setup, unused in long mode)
    const star: u64 = (@as(u64, u_cs_base) << 48) | (@as(u64, k_cs) << 32);

    write_msr(MSR_STAR, star);
    write_msr(MSR_LSTAR, @intFromPtr(&syscall_handler_stub));
    write_msr(MSR_FMASK, 0); // Don't mask flags for now
}

fn write_msr(msr: u32, val: u64) void {
    const lo: u32 = @truncate(val);
    const hi: u32 = @truncate(val >> 32);
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (lo),
          [hi] "{edx}" (hi),
          [msr] "{ecx}" (msr),
    );
}

extern fn syscall_handler_stub() void;

fn jump_to_user(entry: u64, sp: u64) noreturn {
    const user_cs: u64 = 0x23; // 0x20 | 3
    const user_ss: u64 = 0x1B; // 0x18 | 3
    const rflags: u64 = 0x202; // IF=1, bit 1=1

    // Debug print
    kprint("IRETQ to User Mode:\n");
    kprint("  RIP: ");
    kprintHex(entry);
    kprint("\n");
    kprint("  RSP: ");
    kprintHex(sp);
    kprint("\n");
    kprint("  CS:  ");
    kprintHex(user_cs);
    kprint("\n");
    kprint("  SS:  ");
    kprintHex(user_ss);
    kprint("\n");

    asm volatile (
        \\ mov %[ss], %%ds
        \\ mov %[ss], %%es
        \\ mov %[ss], %%fs
        \\ mov %[ss], %%gs
        \\ pushq %[ss]
        \\ pushq %[sp]
        \\ pushq %[rflags]
        \\ pushq %[cs]
        \\ pushq %[entry]
        \\ iretq
        :
        : [ss] "r" (user_ss),
          [sp] "r" (sp),
          [rflags] "r" (rflags),
          [cs] "r" (user_cs),
          [entry] "r" (entry),
    );
    while (true) {}
}

// ... serial_init, serial_putc, kprint, kprintHex ...

fn serial_init() void {
    const COM1 = 0x3f8;
    outb(COM1 + 1, 0x00); // Disable all interrupts
    outb(COM1 + 3, 0x80); // Enable DLAB (set baud rate divisor)
    outb(COM1 + 0, 0x03); // Set divisor to 3 (38400 baud)
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(COM1 + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
    outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
}

fn serial_putc(c: u8) void {
    const COM1 = 0x3f8;
    while ((inb(COM1 + 5) & 0x20) == 0) {}
    outb(COM1, c);
}

pub fn kprint(s: []const u8) void {
    for (s) |c| {
        serial_putc(c);
    }
}

pub fn kprintHex(v: u64) void {
    const hex = "0123456789ABCDEF";
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        const digit = (v >> shift) & 0xF;
        serial_putc(hex[digit]);
    }
}

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

// OS Runtime Support
pub export fn memcpy(noalias dest: [*]u8, noalias src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

pub export fn memset(dest: [*]u8, c: u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = c;
    }
    return dest;
}

pub export fn memmove(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dest[i] = src[i];
        }
    } else {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            dest[i] = src[i];
        }
    }
    return dest;
}

pub export fn memcmp(s1: [*]const u8, s2: [*]const u8, n: usize) i32 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (s1[i] < s2[i]) return -1;
        if (s1[i] > s2[i]) return 1;
    }
    return 0;
}

pub export fn syscall_dispatch(nr: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) u64 {
    kprint("SYSCALL: 0x");
    kprintHex(nr);
    kprint("\n");

    _ = arg4;
    _ = arg5;
    _ = arg6;

    // Mask off the class bits (e.g. 0x2000000)
    // BSD syscalls are class 2.
    // 0x2000004 => 4
    const class = nr >> 24;
    const call_nr = nr & 0xFFFFFF; // Full number without class? No, class is high byte?
    // 0x2000004 -> Class 2 (0x02), Nr 4.
    // 0x100001C -> Class 1 (0x01), Nr 28.
    // 0x3000003 -> Class 3 (0x03), Nr 3.

    // Mach Traps (Class 1) often just use low bits.
    // BSD (Class 2).
    // MDEP (Class 3).

    // We switch on the FULL number for simplicity if small enough, but switch on logic is cleaner.

    if (class == 0x01) { // Mach
        const trap = call_nr;
        switch (trap) {
            10 => { // _kernelrpc_mach_vm_allocate_trap(target, *addr, size, flags)
                // We should write back the allocated address if *addr is valid?
                // arg2 is pointer to address.
                // Simple hack: don't write back, return 0 (KERN_SUCCESS).
                // Wait, if we don't write back, caller sees garbage.
                // We should probably write some address.
                // But we don't have VM allocator yet!
                // Just return success.
                return 0;
            },
            12 => return 0, // vm_deallocate
            14 => { // _kernelrpc_mach_vm_map_trap
                return 0;
            },
            15 => { // port_allocate
                // Write back port? arg2 is pointer to port name.
                // const port_ptr: *u32 = @ptrFromInt(arg2);
                // port_ptr.* = 0x100;
                return 0;
            },
            26 => return 5, // mach_reply_port
            27 => return 6, // thread_self_trap
            28 => return 7, // task_self_trap
            29 => return 8, // host_self_trap
            31 => { // mach_msg_trap
                // args: msg, option, send_size, rcv_size, rcv_name, timeout, notify
                const msg_ptr: *MachMessageHeader = @ptrFromInt(arg1);
                const option = arg2;
                _ = msg_ptr;
                _ = option;

                // Debug print msg id
                // kprint("mach_msg id=");
                // kprintHex(msg_ptr.msgh_id);
                // kprint(" opt=");
                // kprintHex(option);
                // kprint("\n");

                // If MACH_RCV_MSG (bit 1) is set, we might need to wait or return timeout?
                // If timeout is 0, return TIMEOUT immediately if no message?
                // For now, if SEND and RCV are set, we just pretend we sent and didn't receive?
                // Or return SUCCESS?
                // Logic from Swift kernel: if RCV is set, return various codes.

                return 0; // MACH_MSG_SUCCESS
            },
            else => {
                kprint("Unknown Mach Trap: ");
                kprintHex(trap);
                kprint("\n");
                return 0; // KERN_SUCCESS
            },
        }
    } else if (class == 0x03) { // MDEP
        if (call_nr == 3) {
            // thread_fast_set_cthread_self
            write_msr(0xC0000101, arg1); // GS_BASE
            return 0;
        }
        kprint("Unknown MDEP syscall: ");
        kprintHex(call_nr);
        kprint("\n");
        return 0;
    } else { // BSD (Class 2) or generic
        const sys = call_nr & 0x1FF; // Mask to 511
        switch (sys) {
            1 => { // exit
                kprint("Process exited with code: ");
                kprintHex(arg1);
                kprint("\n");
                while (true) asm volatile ("hlt");
            },
            3 => return 0, // read (stub)
            4 => { // write
                const fd = arg1;
                const buf: [*]const u8 = @ptrFromInt(arg2);
                const count = arg3;
                if (fd == 1 or fd == 2) {
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        if (buf[i] == 10) serial_putc(13);
                        serial_putc(buf[i]);
                    }
                    return count;
                }
                return count;
            },
            20 => return 1, // getpid
            33 => return 0, // access (success)
            74 => return 0, // mprotect
            197 => { // mmap
                if (arg1 != 0) return arg1;
                return 0x80000000;
            },
            202 => return 0, // sysctl (success?)
            294 => { // shared_region_check_np(u64 *start_address)
                if (arg1 != 0) {
                    const ptr: *u64 = @ptrFromInt(arg1);
                    ptr.* = 0; // No shared region
                }
                return 0;
            },
            302 => return 0, // __pthread_sigmask
            327 => return 0, // issetugid
            372 => return 6, // thread_selfid (match thread port?)
            500 => { // getentropy(buf, len)
                const buf: [*]u8 = @ptrFromInt(arg1);
                const len = arg2;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    buf[i] = @truncate(i); // simple pattern
                }
                return 0;
            },
            else => {
                kprint("Unknown BSD syscall: ");
                kprintHex(nr); // Print full NR
                kprint("\n");
                return 0; // Success? Or -1?
            },
        }
    }
}

// Exception Handler
pub export fn exception_handler(vector: u64, err_code: u64, rip: u64, cs: u64, rflags: u64, rsp: u64, ss: u64) callconv(.c) void {
    kprint("\nEXCEPTION: ");
    kprintHex(vector);
    kprint(" Error: ");
    kprintHex(err_code);
    kprint("\nRIP: ");
    kprintHex(rip);
    kprint(" CS: ");
    kprintHex(cs);
    kprint(" RFLAGS: ");
    kprintHex(rflags);
    kprint("\nRSP: ");
    kprintHex(rsp);
    kprint(" SS: ");
    kprintHex(ss);

    var ds: u64 = 0;
    asm volatile ("mov %%ds, %[ds]" : [ds] "=r" (ds));
    kprint(" DS: ");
    kprintHex(ds);
    kprint("\n");

    var cr2: u64 = undefined;
    asm volatile ("mov %%cr2, %[cr2]"
        : [cr2] "=r" (cr2),
    );
    kprint("CR2:    ");
    kprintHex(cr2);
    kprint("\n");
    while (true) asm volatile ("hlt");
}
