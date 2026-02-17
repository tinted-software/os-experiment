const pmm = @import("pmm.zig");

pub var pml4: [*]u64 = undefined;

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
    if (getOrAllocTable(&pml4[pml4Index], false) == null) return;
    const pdpt_phys: usize = @intCast(getOrAllocTable(&pml4[pml4Index], false) orelse return);
    const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);

    // PDPT -> PD
    if (getOrAllocTable(&pdpt[pdptIndex], false) == null) return;
    const pd_phys: usize = @intCast(getOrAllocTable(&pdpt[pdptIndex], false) orelse return);
    const pd: [*]u64 = @ptrFromInt(pd_phys);

    // PD -> PT
    if (getOrAllocTable(&pd[pdIndex], true) == null) return;
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

    // Huge page check (PS bit at bit 7 => 0x80 in entry flags for PD)
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
