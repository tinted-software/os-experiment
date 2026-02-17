const std = @import("std");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const multiboot = @import("multiboot.zig");
const cpio = @import("cpio.zig");
const macho = @import("macho.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const vfs = @import("vfs.zig");
const mach_ipc = @import("mach_ipc.zig");
const virtio_block = @import("virtio_block.zig");

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

const MachMessageHeader = extern struct {
    msgh_bits: u32,
    msgh_size: u32,
    msgh_remote_port: u32,
    msgh_local_port: u32,
    msgh_reserved: u32,
    msgh_id: i32,
};

pub export fn kmain(magic: u32, info_addr: u32) callconv(.c) noreturn {
    serial_init();
    kprint("Zig OS Kernel Booting...\n");

    gdt.init(@intFromPtr(&stack_top));
    idt.init();
    vmm.setup();
    virtio_block.init();
    vfs.mountBlockDevice();

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
        }
    }

    if (ramdisk_addr) |rd| {
        const rd_slice = rd[0..ramdisk_len];
        vfs.initRamdisk(rd_slice);
        if (cpio.findFile(rd_slice, "usr/lib/dyld")) |dyld_data| {
            kprint("Found dyld! Loading...\n");

            // Load dyld at 0x10000000 (slide)
            if (loadMachO(dyld_data, 0x10000000)) |dyld_res| {
                kprint("dyld loaded. Entry: 0x");
                kprintHex(dyld_res.entry_point);
                kprint("\n");

                // Load main executable (/bin/zsh) from block device VFS
                const exec_path = "/bin/zsh";
                var exec_mh_addr: u64 = 0;
                const exec_fd_result = vfs.open(exec_path) catch -1;
                if (exec_fd_result >= 0) {
                    if (vfs.getFile(exec_fd_result)) |file| {
                        const exec_data = loadFileToMemory(file);
                        if (exec_data) |data| {
                            const slice = extractX86_64Slice(data);
                            if (loadMachO(slice, 0)) |exec_res| {
                                exec_mh_addr = exec_res.text_base;
                                kprint("Main executable loaded at 0x");
                                kprintHex(exec_mh_addr);
                                kprint("\n");
                            }
                        }
                    }
                }

                if (exec_mh_addr == 0) {
                    kprint("ERROR: Could not load main executable\n");
                    while (true) asm volatile ("hlt");
                }

                setupCommpage();
                enable_features();

                // Setup stack for dyld
                const user_stack_top: u64 = 0x20000000;
                const stackSize: u64 = 0x100000; // 1MB stack
                _ = vmm.mmap(user_stack_top - stackSize, @intCast(stackSize), 7, -1, 0);

                const user_sp = setupDyldStack(exec_path, exec_mh_addr, user_stack_top);

                kprint("Jumping to dyld at 0x");
                kprintHex(dyld_res.entry_point);
                kprint(" SP: 0x");
                kprintHex(user_sp);
                kprint("\n");

                dumpCR3AndPML4();
                dumpPageTables(dyld_res.entry_point);
                jump_to_user(dyld_res.entry_point, user_sp);
            }
        }
    }

    while (true) asm volatile ("hlt");
}

const MachOLoadResult = struct {
    entry_point: u64,
    text_base: u64,
};

fn loadFileToMemory(file: *vfs.FileDescription) ?[]const u8 {
    const size = file.node.size;
    if (size == 0 or size > 64 * 1024 * 1024) return null;
    const addr = vmm.mmap(0, @intCast(size), 7, -1, 0);
    if (addr == 0) return null;
    const buf: [*]u8 = @ptrFromInt(@as(usize, @intCast(addr)));
    const read_bytes = file.node.read(0, @intCast(size), buf);
    if (read_bytes == 0) return null;
    return buf[0..read_bytes];
}

fn byteSwap32(v: u32) u32 {
    return ((v & 0xFF) << 24) | ((v & 0xFF00) << 8) | ((v >> 8) & 0xFF00) | ((v >> 24) & 0xFF);
}

fn extractX86_64Slice(data: []const u8) []const u8 {
    if (data.len < @sizeOf(macho.FatHeader)) return data;
    const magic = std.mem.readInt(u32, data[0..4], .little);
    if (magic != macho.FAT_MAGIC and magic != macho.FAT_CIGAM) return data;

    // FAT is big-endian
    const narch = byteSwap32(std.mem.readInt(u32, data[4..8], .little));
    kprint("FAT binary with ");
    kprintHex(narch);
    kprint(" architectures\n");

    var off: usize = 8;
    var i: u32 = 0;
    while (i < narch) : (i += 1) {
        if (off + @sizeOf(macho.FatArch) > data.len) break;
        const cputype = byteSwap32(std.mem.readInt(u32, data[off..][0..4], .little));
        const arch_offset = byteSwap32(std.mem.readInt(u32, data[off + 8 ..][0..4], .little));
        const arch_size = byteSwap32(std.mem.readInt(u32, data[off + 12 ..][0..4], .little));
        if (cputype == macho.CPU_TYPE_X86_64) {
            kprint("Found x86_64 slice at offset 0x");
            kprintHex(arch_offset);
            kprint(" size 0x");
            kprintHex(arch_size);
            kprint("\n");
            return data[arch_offset..][0..arch_size];
        }
        off += @sizeOf(macho.FatArch);
    }
    kprint("WARNING: No x86_64 slice found in FAT binary\n");
    return data;
}

fn loadMachO(data: []const u8, slide: u64) ?MachOLoadResult {
    if (data.len < @sizeOf(macho.MachHeader64)) return null;
    const header: *const macho.MachHeader64 = @ptrCast(@alignCast(data.ptr));

    if (header.magic != macho.MH_MAGIC_64) return null;

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
                if (isSegName(&seg.segname, "__PAGEZERO")) {
                    // Skip __PAGEZERO
                } else {
                    if (isSegName(&seg.segname, "__TEXT")) {
                        result.text_base = seg.vmaddr + slide;
                    }
                    if (seg.vmsize > 0) {
                        const dest_addr = seg.vmaddr + slide;
                        _ = vmm.mmap(dest_addr, @intCast(seg.vmsize), 7, -1, 0);
                        const dest: [*]u8 = @ptrFromInt(@as(usize, @intCast(dest_addr)));
                        if (seg.filesize > 0) {
                            @memcpy(dest[0..@intCast(seg.filesize)], data[seg.fileoff..][0..@intCast(seg.filesize)]);
                        }
                        kprint("  seg ");
                        kprintN(&seg.segname, 16);
                        kprint(" -> 0x");
                        kprintHex(dest_addr);
                        kprint(" (0x");
                        kprintHex(seg.vmsize);
                        kprint(")\n");
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
                if (thread.flavor == 4) {
                    const regs_ptr = @as([*]const u64, @ptrCast(@alignCast(@as([*]const u8, @ptrCast(cmd)) + 16)));
                    result.entry_point = regs_ptr[16];
                }
            },
            else => {},
        }
        cmd_offset += cmd.cmdsize;
    }

    if (entry_is_relative) {
        result.entry_point += result.text_base;
    } else {
        result.entry_point += slide;
    }

    return result;
}

fn isSegName(segname: *const [16]u8, name: []const u8) bool {
    if (name.len > 16) return false;
    for (0..name.len) |idx| {
        if (segname[idx] != name[idx]) return false;
    }
    if (name.len < 16 and segname[name.len] != 0) return false;
    return true;
}

fn kprintN(buf: *const [16]u8, max: usize) void {
    for (0..max) |idx| {
        if (buf[idx] == 0) break;
        serial_putc(buf[idx]);
    }
}

fn setupDyldStack(exec_path: []const u8, exec_mh_addr: u64, user_stack_top: u64) u64 {
    // Place strings at top of stack area
    var str_ptr = user_stack_top - 0x100;

    // Write "executable_path=/bin/zsh" apple string
    const apple_prefix = "executable_path=";
    const apple_str_len = apple_prefix.len + exec_path.len + 1;
    str_ptr -= apple_str_len;
    const apple_str_addr = str_ptr;
    var dest: [*]u8 = @ptrFromInt(@as(usize, @intCast(str_ptr)));
    @memcpy(dest[0..apple_prefix.len], apple_prefix);
    @memcpy(dest[apple_prefix.len..][0..exec_path.len], exec_path);
    dest[apple_prefix.len + exec_path.len] = 0;

    // Write argv[0] string
    str_ptr -= exec_path.len + 1;
    const argv0_addr = str_ptr;
    dest = @ptrFromInt(@as(usize, @intCast(str_ptr)));
    @memcpy(dest[0..exec_path.len], exec_path);
    dest[exec_path.len] = 0;

    // Align stack pointer
    var sp = str_ptr - 0x100;
    sp &= ~@as(u64, 0xF);

    // Stack layout dyld expects (from bottom to top):
    //   [0] = mh pointer (main executable Mach-O header)
    //   [1] = argc
    //   [2] = argv[0]
    //   [3] = argv terminator (NULL)
    //   [4] = envp terminator (NULL)
    //   [5] = apple[0] = "executable_path=..."
    //   [6] = apple terminator (NULL)
    const frame: [*]u64 = @ptrFromInt(@as(usize, @intCast(sp - 7 * 8)));
    frame[0] = exec_mh_addr; // Main executable's Mach-O header
    frame[1] = 1; // argc
    frame[2] = argv0_addr; // argv[0]
    frame[3] = 0; // argv terminator
    frame[4] = 0; // envp terminator
    frame[5] = apple_str_addr; // apple[0]
    frame[6] = 0; // apple terminator

    return @intFromPtr(frame);
}

fn setupCommpage() void {
    // XNU commpage at 0x7FFFFFE00000 (64-bit commpage base)
    const commpage_base: u64 = 0x7FFFFFE00000;
    _ = vmm.mmap(commpage_base, 4096, 5, -1, 0); // R-X for user

    const page: [*]u8 = @ptrFromInt(@as(usize, @intCast(commpage_base)));
    @memset(page[0..4096], 0);

    // Commpage version at offset 0x1E (UInt16) — must be >= 14 for newer dyld
    const version_ptr: *align(1) u16 = @ptrFromInt(@as(usize, @intCast(commpage_base + 0x1E)));
    version_ptr.* = 13; // Version < 14 so dyld uses default page shift (12)

    // CPU capabilities at offset 0x10 (UInt64)
    const caps_ptr: *align(1) u64 = @ptrFromInt(@as(usize, @intCast(commpage_base + 0x10)));
    caps_ptr.* = 0; // Basic x86_64

    // Signature "commpage" at offset 0 (optional, some code checks)
    const sig = "commpage 64";
    @memcpy(page[0..sig.len], sig);

    kprint("Commpage mapped at 0x");
    kprintHex(commpage_base);
    kprint("\n");
}

const MSR_STAR = 0xC0000081;
const MSR_LSTAR = 0xC0000082;
const MSR_FMASK = 0xC0000084;
const MSR_EFER = 0xC0000080;

fn enable_features() void {
    var cr4: u64 = undefined;
    asm volatile ("mov %%cr4, %[cr4]" : [cr4] "=r" (cr4));
    cr4 |= (1 << 16); // FSGSBASE
    asm volatile ("mov %[cr4], %%cr4" :: [cr4] "r" (cr4));

    var efer_lo: u32 = undefined;
    var efer_hi: u32 = undefined;
    asm volatile ("rdmsr" : [lo] "={eax}" (efer_lo), [hi] "={edx}" (efer_hi) : [msr] "{ecx}" (@as(u32, MSR_EFER)));
    efer_lo |= 1; // SCE
    asm volatile ("wrmsr" :: [lo] "{eax}" (efer_lo), [hi] "{edx}" (efer_hi), [msr] "{ecx}" (@as(u32, MSR_EFER)));

    setup_syscalls();
}

fn setup_syscalls() void {
    const k_cs = 0x08;
    const u_cs_base = 0x10;
    const star: u64 = (@as(u64, u_cs_base) << 48) | (@as(u64, k_cs) << 32);
    write_msr(MSR_STAR, star);
    write_msr(MSR_LSTAR, @intFromPtr(&syscall_handler_stub));
    write_msr(MSR_FMASK, 0);
}

fn write_msr(msr: u32, val: u64) void {
    const lo: u32 = @truncate(val);
    const hi: u32 = @truncate(val >> 32);
    asm volatile ("wrmsr" :: [lo] "{eax}" (lo), [hi] "{edx}" (hi), [msr] "{ecx}" (msr));
}

extern fn syscall_handler_stub() void;

fn jump_to_user(entry: u64, sp: u64) noreturn {
    const user_cs: u64 = 0x23; // 0x20 | 3
    const user_ss: u64 = 0x1B; // 0x18 | 3
    const rflags: u64 = 0x202;

    kprint("IRETQ to User Mode:\n");
    kprint("  RIP: "); kprintHex(entry); kprint("\n");
    kprint("  RSP: "); kprintHex(sp); kprint("\n");
    kprint("  CS:  "); kprintHex(user_cs); kprint("\n");
    kprint("  SS:  "); kprintHex(user_ss); kprint("\n");

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
        : [ss] "r" (user_ss), [sp] "r" (sp), [rflags] "r" (rflags), [cs] "r" (user_cs), [entry] "r" (entry),
    );
    while (true) {}
}

fn dumpPageTables(virt: u64) void {
    const pml4Index: usize = @intCast((virt >> 39) & 0x1FF);
    const pdptIndex: usize = @intCast((virt >> 30) & 0x1FF);
    const pdIndex: usize = @intCast((virt >> 21) & 0x1FF);
    const ptIndex: usize = @intCast((virt >> 12) & 0x1FF);

    kprint("Page tables for "); kprintHex(virt); kprint("\n");
    const pml4e = vmm.pml4[pml4Index];
    kprint(" PML4["); kprintHex(@as(u64, pml4Index)); kprint("]: "); kprintHex(pml4e); kprint("\n");
    if ((pml4e & 1) == 0) return;
    const pdpt: [*]u64 = @ptrFromInt(@as(usize, @intCast(pml4e & ~(@as(u64, 0xFFF)))));
    const pdpte = pdpt[pdptIndex];
    kprint(" PDPT["); kprintHex(@as(u64, pdptIndex)); kprint("]: "); kprintHex(pdpte); kprint("\n");
    if ((pdpte & 1) == 0) return;
    const pd: [*]u64 = @ptrFromInt(@as(usize, @intCast(pdpte & ~(@as(u64, 0xFFF)))));
    const pde = pd[pdIndex];
    kprint(" PD["); kprintHex(@as(u64, pdIndex)); kprint("]: "); kprintHex(pde); kprint("\n");
    if ((pde & 1) == 0) return;
    if ((pde & @as(u64, 0x80)) != 0) {
        kprint(" 2MB huge page\n"); return;
    }
    const pt: [*]u64 = @ptrFromInt(@as(usize, @intCast(pde & ~(@as(u64, 0xFFF)))));
    const pte = pt[ptIndex];
    kprint(" PT["); kprintHex(@as(u64, ptIndex)); kprint("]: "); kprintHex(pte); kprint("\n");
}

fn dumpCR3AndPML4() void {
    var cr3: u64 = undefined;
    asm volatile ("mov %%cr3, %[cr3]" : [cr3] "=r" (cr3));
    kprint("CR3: 0x"); kprintHex(cr3); kprint("\n");
    kprint("vmm.pml4 ptr: "); kprintHex(@as(u64, @intFromPtr(vmm.pml4))); kprint("\n");
}

fn serial_init() void {
    const COM1 = 0x3f8;
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x80);
    outb(COM1 + 0, 0x03);
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);
    outb(COM1 + 2, 0xC7);
    outb(COM1 + 4, 0x0B);
}

fn serial_putc(c: u8) void {
    const COM1 = 0x3f8;
    while ((inb(COM1 + 5) & 0x20) == 0) {}
    outb(COM1, c);
}

pub fn kprint(s: []const u8) void {
    for (s) |c| serial_putc(c);
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
    asm volatile ("outb %[val], %[port]" :: [val] "{al}" (val), [port] "{dx}" (port));
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]" : [ret] "={al}" (-> u8) : [port] "{dx}" (port));
}

pub export fn syscall_dispatch(nr: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) u64 {
    kprint("SYSCALL: 0x"); kprintHex(nr);
    kprint(" ("); kprintHex(arg1); kprint(", "); kprintHex(arg2); kprint(", "); kprintHex(arg3); kprint(")");

    const class = nr >> 24;
    const call_nr = nr & 0xFFFFFF;

    const res = dispatch(class, call_nr, arg1, arg2, arg3, arg4, arg5, arg6);
    kprint(" -> 0x"); kprintHex(res); kprint("\n");
    return res;
}

fn dispatch(class: u64, call_nr: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) u64 {
    if (class == 0x01) { // Mach
        switch (call_nr) {
            10 => { // _kernelrpc_mach_vm_allocate_trap(target, addr_p, size, flags)
                const addr_ptr: ?*u64 = @ptrFromInt(@as(usize, @intCast(arg2)));
                const size = arg3;
                const addr = vmm.mmap(0, @intCast(size), 7, -1, 0);
                if (addr_ptr) |p| p.* = addr;
                return 0;
            },
            12 => return 0, // _kernelrpc_mach_vm_deallocate_trap
            14 => return 0, // _kernelrpc_mach_vm_protect_trap
            15 => return 0, // _kernelrpc_mach_vm_map_trap
            16 => { // _kernelrpc_mach_port_allocate_trap(target, right, name_out)
                const name_ptr: ?*u32 = @ptrFromInt(@as(usize, @intCast(arg3)));
                const name = mach_ipc.machPortAllocate(@truncate(arg2));
                if (name_ptr) |p| p.* = name;
                return 0;
            },
            18 => return 0, // _kernelrpc_mach_port_deallocate_trap
            19 => return 0, // _kernelrpc_mach_port_mod_refs_trap
            21 => return 0, // _kernelrpc_mach_port_insert_right_trap
            24 => { // _kernelrpc_mach_port_construct_trap(target, options, context, name_out)
                const name_ptr: ?*u32 = @ptrFromInt(@as(usize, @intCast(arg4)));
                const name = mach_ipc.machPortAllocate(1);
                if (name_ptr) |p| p.* = name;
                return 0;
            },
            25 => return 0, // _kernelrpc_mach_port_destruct_trap
            26 => return mach_ipc.machReplyPort(),
            27 => return 0x203, // thread_self_trap
            28 => return mach_ipc.machTaskSelf(),
            29 => return mach_ipc.machHostSelf(),
            31, 32 => return mach_ipc.handleMachMsg(arg1, @truncate(arg2), @truncate(arg3), @truncate(arg4), @truncate(arg5), @truncate(arg6)),
            33 => return 0, // semaphore_signal_trap
            36 => return 0, // semaphore_wait_trap
            else => {
                kprint("  [unhandled Mach "); kprintHex(call_nr); kprint("]\n");
                return 0;
            },
        }
    } else if (class == 0x03) { // MDEP
        if (call_nr == 3) {
            write_msr(0xC0000102, arg1);
            return 0;
        }
        return 0;
    } else { // BSD
        switch (call_nr) {
            1 => { // exit
                kprint("Process exited code: "); kprintHex(arg1); kprint("\n");
                while (true) asm volatile ("hlt");
            },
            3 => { // read
                const fd: i32 = @bitCast(@as(u32, @truncate(arg1)));
                if (vfs.getFile(fd)) |file| {
                    const bytes = file.node.read(file.offset, @intCast(arg3), @ptrFromInt(@as(usize, @intCast(arg2))));
                    file.offset += bytes;
                    return bytes;
                }
                // Return random data for unknown fds (e.g. /dev/random proxy)
                const buf: [*]u8 = @ptrFromInt(@as(usize, @intCast(arg2)));
                fillRandom(buf[0..arg3]);
                return arg3;
            },
            4 => { // write
                const fd = arg1;
                const buf: [*]const u8 = @ptrFromInt(@as(usize, @intCast(arg2)));
                const count = arg3;
                if (fd == 1 or fd == 2) {
                    var idx: usize = 0;
                    while (idx < count) : (idx += 1) {
                        serial_putc(buf[idx]);
                    }
                    return count;
                }
                return count;
            },
            5 => { // open
                const path: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(arg1)));
                const path_slice = std.mem.span(path);
                kprint("open(\"");
                kprint(path_slice);
                kprint("\")");
                const fd = vfs.open(path_slice) catch -1;
                if (fd == -1) {
                    kprint(" -> ENOENT\n");
                    return @as(u64, @bitCast(@as(i64, -2))); // ENOENT
                }
                return @as(u64, @bitCast(@as(i64, fd)));
            },
            6 => { vfs.close(@intCast(arg1)); return 0; }, // close
            20 => return 1, // getpid
            24, 25 => return 0, // getuid, geteuid
            33 => return @as(u64, @bitCast(@as(i64, -2))), // access -> ENOENT
            43, 47 => return 0, // getegid, getgid
            46 => return 0, // sigaction
            48 => { // sigprocmask
                if (arg3 != 0) {
                    const oset: *u64 = @ptrFromInt(@as(usize, @intCast(arg3)));
                    oset.* = 0;
                }
                return 0;
            },
            54 => return 0, // ioctl
            73 => return 0, // munmap
            74 => return 0, // mprotect
            90 => return arg2, // dup2
            92 => return 0, // fcntl
            121 => { // writev
                if (arg2 == 0) return 0;
                const iov: [*]const [2]u64 = @ptrFromInt(@as(usize, @intCast(arg2)));
                var total: u64 = 0;
                var idx: usize = 0;
                while (idx < arg3) : (idx += 1) {
                    const base = iov[idx][0];
                    const len = iov[idx][1];
                    if (base != 0 and len > 0) {
                        const buf: [*]const u8 = @ptrFromInt(@as(usize, @intCast(base)));
                        var j: usize = 0;
                        while (j < len) : (j += 1) {
                            serial_putc(buf[j]);
                        }
                        total += len;
                    }
                }
                return total;
            },
            169, 170 => return 0, // csops, csops_audittoken
            194 => { // getrlimit
                if (arg2 != 0) {
                    const rlp: [*]u64 = @ptrFromInt(@as(usize, @intCast(arg2)));
                    rlp[0] = 0x800000; // 8MB cur
                    rlp[1] = 0x800000; // 8MB max
                }
                return 0;
            },
            195 => return 0, // setrlimit
            197 => { // mmap
                const fd: i32 = @bitCast(@as(u32, @truncate(arg5)));
                return vmm.mmap(arg1, @intCast(arg2), 7, fd, arg6);
            },
            202 => { // sysctl
                return handleSysctl(arg1, arg2, arg3, arg4);
            },
            274 => return 0, // sysctlbyname
            294 => { // shared_region_check_np
                if (arg1 != 0) {
                    const ptr: *u64 = @ptrFromInt(@as(usize, @intCast(arg1)));
                    ptr.* = 0;
                }
                return 0;
            },
            302, 327 => return 0, // __pthread_mutex_init, issetugid
            336 => return 0, // proc_info
            338 => { // stat64
                const path: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(arg1)));
                const path_slice = std.mem.span(path);
                kprint("stat64(\"");
                kprint(path_slice);
                kprint("\")\n");
                if (vfs.resolve(path_slice)) |node| {
                    return fillStatBuf(arg2, node);
                }
                return @as(u64, @bitCast(@as(i64, -2))); // ENOENT
            },
            339 => { // fstat64
                const fd: i32 = @bitCast(@as(u32, @truncate(arg1)));
                if (vfs.getFile(fd)) |file| {
                    return fillStatBuf(arg2, file.node);
                }
                return @as(u64, @bitCast(@as(i64, -9))); // EBADF
            },
            340 => return @as(u64, @bitCast(@as(i64, -2))), // lstat64 -> ENOENT
            366 => return 0, // bsdthread_register
            372 => return 1, // thread_selfid
            396 => { // read_nocancel
                const fd: i32 = @bitCast(@as(u32, @truncate(arg1)));
                if (vfs.getFile(fd)) |file| {
                    const bytes = file.node.read(file.offset, @intCast(arg3), @ptrFromInt(@as(usize, @intCast(arg2))));
                    file.offset += bytes;
                    return bytes;
                }
                return @as(u64, @bitCast(@as(i64, -9)));
            },
            397 => { // write_nocancel
                const buf: [*]const u8 = @ptrFromInt(@as(usize, @intCast(arg2)));
                if (arg1 == 1 or arg1 == 2) {
                    var idx: usize = 0;
                    while (idx < arg3) : (idx += 1) serial_putc(buf[idx]);
                    return arg3;
                }
                return arg3;
            },
            398 => { // open_nocancel
                const path: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(arg1)));
                const path_slice = std.mem.span(path);
                kprint("open(\"");
                kprint(path_slice);
                kprint("\")");
                const fd = vfs.open(path_slice) catch -1;
                if (fd == -1) {
                    kprint(" -> ENOENT\n");
                    return @as(u64, @bitCast(@as(i64, -2)));
                }
                return @as(u64, @bitCast(@as(i64, fd)));
            },
            399 => { vfs.close(@intCast(arg1)); return 0; }, // close_nocancel
            500 => { // getentropy
                const buf: [*]u8 = @ptrFromInt(@as(usize, @intCast(arg1)));
                fillRandom(buf[0..arg2]);
                return 0;
            },
            520 => { // terminate_with_payload
                kprint("terminate_with_payload(pid="); kprintHex(arg1); kprint(")\n");
                while (true) asm volatile ("hlt");
            },
            521 => { // abort_with_payload
                kprint("abort_with_payload()\n");
                while (true) asm volatile ("hlt");
            },
            else => {
                kprint("  [unhandled BSD "); kprintHex(call_nr); kprint("]\n");
                return 0;
            },
        }
    }
}

fn handleSysctl(name_addr: u64, namelen: u64, oldp_addr: u64, oldlenp_addr: u64) u64 {
    if (namelen < 2) return 0;
    const name: [*]const i32 = @ptrFromInt(@as(usize, @intCast(name_addr)));
    const mib0 = name[0];
    const mib1 = name[1];

    // CTL_KERN=1, KERN_OSTYPE=1
    if (mib0 == 1 and mib1 == 1) {
        if (oldp_addr != 0) {
            const oldp: [*]u8 = @ptrFromInt(@as(usize, @intCast(oldp_addr)));
            const ostype = "Darwin";
            @memcpy(oldp[0..ostype.len], ostype);
            oldp[ostype.len] = 0;
        }
        if (oldlenp_addr != 0) {
            const lenp: *u64 = @ptrFromInt(@as(usize, @intCast(oldlenp_addr)));
            lenp.* = 7;
        }
        return 0;
    }
    // CTL_KERN=1, KERN_OSRELEASE=2
    if (mib0 == 1 and mib1 == 2) {
        if (oldp_addr != 0) {
            const oldp: [*]u8 = @ptrFromInt(@as(usize, @intCast(oldp_addr)));
            const osrel = "23.0.0";
            @memcpy(oldp[0..osrel.len], osrel);
            oldp[osrel.len] = 0;
        }
        if (oldlenp_addr != 0) {
            const lenp: *u64 = @ptrFromInt(@as(usize, @intCast(oldlenp_addr)));
            lenp.* = 7;
        }
        return 0;
    }
    // CTL_KERN=1, KERN_VERSION=4
    if (mib0 == 1 and mib1 == 4) {
        if (oldp_addr != 0) {
            const oldp: [*]u8 = @ptrFromInt(@as(usize, @intCast(oldp_addr)));
            const ver = "ZigOS 0.1";
            @memcpy(oldp[0..ver.len], ver);
            oldp[ver.len] = 0;
        }
        if (oldlenp_addr != 0) {
            const lenp: *u64 = @ptrFromInt(@as(usize, @intCast(oldlenp_addr)));
            lenp.* = 10;
        }
        return 0;
    }
    // CTL_KERN=1, KERN_OSVERSION=65
    if (mib0 == 1 and mib1 == 65) {
        if (oldp_addr != 0) {
            const oldp: [*]u8 = @ptrFromInt(@as(usize, @intCast(oldp_addr)));
            const build = "23A344";
            @memcpy(oldp[0..build.len], build);
            oldp[build.len] = 0;
        }
        if (oldlenp_addr != 0) {
            const lenp: *u64 = @ptrFromInt(@as(usize, @intCast(oldlenp_addr)));
            lenp.* = 7;
        }
        return 0;
    }
    // CTL_HW=6, HW_NCPU=3
    if (mib0 == 6 and mib1 == 3) {
        if (oldp_addr != 0) {
            const oldp: *i32 = @ptrFromInt(@as(usize, @intCast(oldp_addr)));
            oldp.* = 1;
        }
        return 0;
    }
    // CTL_HW=6, HW_MEMSIZE=24
    if (mib0 == 6 and mib1 == 24) {
        if (oldp_addr != 0) {
            const oldp: *u64 = @ptrFromInt(@as(usize, @intCast(oldp_addr)));
            oldp.* = 1024 * 1024 * 1024; // 1GB
        }
        return 0;
    }
    // CTL_HW=6, HW_PAGESIZE=7
    if (mib0 == 6 and mib1 == 7) {
        if (oldp_addr != 0) {
            const oldp: *i32 = @ptrFromInt(@as(usize, @intCast(oldp_addr)));
            oldp.* = 4096;
        }
        return 0;
    }
    return 0;
}

fn fillStatBuf(stat_addr: u64, node: *const vfs.VNode) u64 {
    const stat_ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(stat_addr)));
    @memset(stat_ptr[0..144], 0);
    // st_mode at offset 4 (UInt16): S_IFREG=0x8000 | 0o644
    const mode: u16 = if (node.type == .file) 0x8000 | 0o644 else 0x4000 | 0o755;
    const mode_ptr: *align(1) u16 = @ptrFromInt(@as(usize, @intCast(stat_addr + 4)));
    mode_ptr.* = mode;
    // st_size at offset 96 (Int64)
    const size_ptr: *align(1) u64 = @ptrFromInt(@as(usize, @intCast(stat_addr + 96)));
    size_ptr.* = node.size;
    return 0;
}

pub fn fillRandom(buffer: []u8) void {
    var val: u64 = 0;
    asm volatile ("rdrand %[val]" : [val] "=r" (val) :: "cc");
    var r = std.Random.DefaultPrng.init(val);
    r.random().bytes(buffer);
}

pub export fn exception_handler(vector: u64, err_code: u64, rip: u64, cs: u64, rflags: u64, rsp: u64, ss: u64) callconv(.c) void {
    kprint("\nEXCEPTION: "); kprintHex(vector);
    kprint(" Error: "); kprintHex(err_code);
    kprint("\nRIP: "); kprintHex(rip);
    kprint(" CS: "); kprintHex(cs);
    kprint(" RFLAGS: "); kprintHex(rflags);
    kprint("\nRSP: "); kprintHex(rsp);
    kprint(" SS: "); kprintHex(ss);

    var ds: u64 = 0;
    asm volatile ("mov %%ds, %[ds]" : [ds] "=r" (ds));
    kprint(" DS: "); kprintHex(ds);

    const MSR_GS_BASE = 0xC0000101;
    const MSR_KERNEL_GS_BASE = 0xC0000102;
    var gs_base: u64 = undefined;
    var k_gs_base: u64 = undefined;
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr" : [lo] "={eax}" (lo), [hi] "={edx}" (hi) : [msr] "{ecx}" (@as(u32, MSR_GS_BASE)));
    gs_base = (@as(u64, hi) << 32) | lo;
    asm volatile ("rdmsr" : [lo] "={eax}" (lo), [hi] "={edx}" (hi) : [msr] "{ecx}" (@as(u32, MSR_KERNEL_GS_BASE)));
    k_gs_base = (@as(u64, hi) << 32) | lo;
    kprint(" GS: "); kprintHex(gs_base);
    kprint(" KGS: "); kprintHex(k_gs_base);
    kprint("\n");

    var cr2: u64 = undefined;
    asm volatile ("mov %%cr2, %[cr2]" : [cr2] "=r" (cr2));
    kprint("CR2:    "); kprintHex(cr2); kprint("\n");
    while (true) asm volatile ("hlt");
}
