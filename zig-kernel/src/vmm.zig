const std = @import("std");
const pmm = @import("pmm.zig");
const vfs = @import("vfs.zig");
const main = @import("main.zig");

pub var pml4: [*]u64 = undefined;
pub var next_mmap_addr: u64 = 0x4000_0000; // 1GB

pub const VMMRegion = struct {
    virt: u64,
    size: usize,
    flags: u64,
    fd: i32 = -1,
    offset: u64 = 0,
};

var regions: [256]?VMMRegion = [_]?VMMRegion{null} ** 256;

pub fn mmap(addr: u64, len: usize, flags: u64, fd: i32, offset: u64) u64 {
    var actual_addr = addr;
    if (actual_addr == 0) {
        actual_addr = next_mmap_addr;
        next_mmap_addr += (len + 4095) & ~@as(u64, 4095);
    }

    const pages = (len + 4095) / 4096;
    for (0..pages) |i| {
        if (pmm.allocateFrame()) |frame| {
            // Default to Present|RW|User
            map(actual_addr + i * 4096, frame, flags | 7);
        }
    }

    if (fd != -1) {
        if (vfs.getFile(fd)) |file| {
            _ = file.node.read(offset, len, @ptrFromInt(@as(usize, @intCast(actual_addr))));
        }
    }

    // Track region
    for (0..regions.len) |i| {
        if (regions[i] == null) {
            regions[i] = VMMRegion{
                .virt = actual_addr,
                .size = len,
                .flags = flags,
                .fd = fd,
                .offset = offset,
            };
            break;
        }
    }

    return actual_addr;
}

pub fn setup() void {
    var cr3: u64 = undefined;
    asm volatile ("mov %%cr3, %[cr3]"
        : [cr3] "=r" (cr3),
    );
    const phys_pml4: usize = @intCast(cr3 & ~@as(u64, 0xFFF));
    pml4 = @ptrFromInt(phys_pml4);
}

pub fn map(virt: u64, phys: usize, flags: u64) void {
    const pml4Index: usize = @intCast((virt >> 39) & 0x1FF);
    const pdptIndex: usize = @intCast((virt >> 30) & 0x1FF);
    const pdIndex: usize = @intCast((virt >> 21) & 0x1FF);
    const ptIndex: usize = @intCast((virt >> 12) & 0x1FF);

    // PML4 -> PDPT
    const pdpt_phys: usize = @intCast(getOrAllocTable(&pml4[pml4Index], false) orelse return);
    const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);

    // PDPT -> PD
    const pd_phys: usize = @intCast(getOrAllocTable(&pdpt[pdptIndex], false) orelse return);
    const pd: [*]u64 = @ptrFromInt(pd_phys);

    // PD -> PT
    const pt_phys: usize = @intCast(getOrAllocTable(&pd[pdIndex], true) orelse return);
    const pt: [*]u64 = @ptrFromInt(pt_phys);

    // PT Entry
    pt[ptIndex] = @as(u64, phys) | flags | 1; // Present

    const addr_ptr: *const u8 = @ptrFromInt(@as(usize, @intCast(virt)));
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr_ptr),
    );
}

fn getOrAllocTable(entry: *u64, isL2: bool) ?usize {
    const val: u64 = entry.*;
    if ((val & 1) == 0) {
        if (pmm.allocateFrame()) |frame| {
            const v = @as(u64, frame) | 7; // Present|RW|User
            entry.* = v;
            return frame;
        } else {
            return null;
        }
    }

    if ((val & 0x80) != 0) {
        if (isL2) {
            return split2MBPage(entry);
        }
        return null;
    }

    return @intCast(val & ~(@as(u64, 0xFFF)));
}

fn split2MBPage(entry: *u64) ?usize {
    const hugePagePhys: u64 = entry.* & ~(@as(u64, 0x1FFFFF));
    const hugePageFlags: u64 = entry.* & @as(u64, 0x1FF);
    const ptFlags: u64 = hugePageFlags & ~(@as(u64, 0x80));

    const frame = pmm.allocateFrame() orelse return null;
    const pt: [*]u64 = @ptrFromInt(frame);

    var i: usize = 0;
    while (i < 512) : (i += 1) {
        pt[i] = hugePagePhys + @as(u64, i * 4096) | ptFlags;
    }

    entry.* = @as(u64, frame) | 7;
    return frame;
}
