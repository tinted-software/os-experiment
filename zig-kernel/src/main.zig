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

// ... imports ...

// ... defines ...

pub export fn kmain(magic: u32, info_addr: u32) callconv(.c) noreturn {
    serial_init();
    kprint("Zig OS Kernel Booting...\n");
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

                // Setup stack for dyld
                const user_stack_top: u64 = 0x70000000;
                // Zero out the stack page (4KB)
                const stack_page: [*]u8 = @ptrFromInt(user_stack_top - 0x1000);
                _ = memset(stack_page, 0, 0x1000);

                const user_sp = setupDyldStack("init", res.text_base, res.entry_point, user_stack_top);

                kprint("Jumping to dyld at 0x");
                kprintHex(res.entry_point);
                kprint(" SP: 0x");
                kprintHex(user_sp);
                kprint("\n");

                jump_to_user(res.entry_point, user_sp);
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

fn jump_to_user(entry: u64, sp: u64) noreturn {
    // We are in kernel mode (Ring 0). To jump to "user" mode (Ring 3) or just run this code in Ring 0 for now?
    // SwiftOS `jump_to_user` likely uses `iretq` or `sysret`.
    // For now, since we haven't set up GDT for user mode fully (TSS etc properly), let's just jump to it in kernel mode?
    // But `dyld` might expect to be in user mode.
    // However, simplest step is `jmp` or `call`.
    // But stack pointer must be switched.

    // Switch stack and jump
    asm volatile (
        \\ mov %[sp], %%rsp
        \\ jmp *%[entry]
        :
        : [sp] "r" (sp),
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
    kprint("\n");
    while (true) asm volatile ("hlt");
}
