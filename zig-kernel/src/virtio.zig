const std = @import("std");
const main = @import("main.zig");

pub const VIRTIO_PCI_VENDOR: u16 = 0x1AF4;

pub const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
pub const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
pub const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;
pub const VIRTIO_PCI_CAP_DEVICE_CFG: u8 = 4;

pub const VirtioPciCommonCfg = extern struct {
    device_feature_select: u32,
    device_feature: u32,
    driver_feature_select: u32,
    driver_feature: u32,
    config_msix_vector: u16,
    num_queues: u16,
    device_status: u8,
    config_generation: u8,
    queue_select: u16,
    queue_size: u16,
    queue_msix_vector: u16,
    queue_enable: u16,
    queue_notify_off: u16,
    queue_desc: u64,
    queue_driver: u64,
    queue_device: u64,
};

pub const VirtioConfig = struct {
    common: ?*volatile VirtioPciCommonCfg = null,
    notify: ?[*]volatile u16 = null,
    isr: ?*volatile u8 = null,
    device: ?[*]volatile u8 = null,
    notify_off_multiplier: u32 = 0,
};

pub const PciDevice = struct {
    bus: u8,
    slot: u8,
    func: u8,
};

pub fn scanPci(vendor: u16, device: u16) ?PciDevice {
    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        const v = pciRead16(0, slot, 0, 0);
        if (v == 0xFFFF) continue;
        const d = pciRead16(0, slot, 0, 2);

        if (v == vendor and d == device) {
            return PciDevice{ .bus = 0, .slot = slot, .func = 0 };
        }
    }
    return null;
}

pub fn parseCapabilities(dev: PciDevice, config: *VirtioConfig) void {
    var cap_ptr = pciRead8(dev.bus, dev.slot, dev.func, 0x34);
    while (cap_ptr != 0) {
        const cap_id = pciRead8(dev.bus, dev.slot, dev.func, cap_ptr);
        if (cap_id == 0x09) { // Vendor Specific
            const cfg_type = pciRead8(dev.bus, dev.slot, dev.func, cap_ptr + 3);
            const bar_idx = pciRead8(dev.bus, dev.slot, dev.func, cap_ptr + 4);
            const offset = pciRead32(dev.bus, dev.slot, dev.func, cap_ptr + 8);
            // const length = pciRead32(dev.bus, dev.slot, dev.func, cap_ptr + 12);

            const bar_raw = pciRead32(dev.bus, dev.slot, dev.func, 0x10 + bar_idx * 4);
            const bar_addr = bar_raw & 0xFFFFFFF0;
            
            const addr: usize = @intCast(bar_addr + offset);

            switch (cfg_type) {
                VIRTIO_PCI_CAP_COMMON_CFG => {
                    config.common = @ptrFromInt(addr);
                },
                VIRTIO_PCI_CAP_NOTIFY_CFG => {
                    config.notify = @ptrFromInt(addr);
                    config.notify_off_multiplier = pciRead32(dev.bus, dev.slot, dev.func, cap_ptr + 16);
                },
                VIRTIO_PCI_CAP_ISR_CFG => {
                    config.isr = @ptrFromInt(addr);
                },
                VIRTIO_PCI_CAP_DEVICE_CFG => {
                    config.device = @ptrFromInt(addr);
                },
                else => {},
            }
        }
        cap_ptr = pciRead8(dev.bus, dev.slot, dev.func, cap_ptr + 1);
    }
}

pub fn pciRead8(bus: u8, slot: u8, func: u8, offset: u8) u8 {
    return @truncate(pciRead32(bus, slot, func, offset) >> @as(u5, @intCast((offset % 4) * 8)));
}

pub fn pciRead16(bus: u8, slot: u8, func: u8, offset: u8) u16 {
    return @truncate(pciRead32(bus, slot, func, offset) >> @as(u5, @intCast((offset % 4) * 8)));
}

pub fn pciRead32(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const address = (@as(u32, bus) << 16) | (@as(u32, slot) << 11) | (@as(u32, func) << 8) | (@as(u32, offset) & 0xfc) | 0x80000000;
    outl(0xCF8, address);
    return inl(0xCFC);
}

pub fn pciWrite16(bus: u8, slot: u8, func: u8, offset: u8, val: u16) void {
    const old = pciRead32(bus, slot, func, offset);
    const shift = @as(u5, @intCast((offset % 4) * 8));
    const mask = ~(@as(u32, 0xFFFF) << shift);
    const new = (old & mask) | (@as(u32, val) << shift);
    
    const address = (@as(u32, bus) << 16) | (@as(u32, slot) << 11) | (@as(u32, func) << 8) | (@as(u32, offset) & 0xfc) | 0x80000000;
    outl(0xCF8, address);
    outl(0xCFC, new);
}

fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "{dx}" (port),
    );
}

fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    // ring: [N]u16
};

pub const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};

pub const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    // ring: [N]VirtqUsedElem
};

pub const VIRTQ_DESC_F_NEXT: u16 = 1;
pub const VIRTQ_DESC_F_WRITE: u16 = 2;
pub const VIRTQ_DESC_F_INDIRECT: u16 = 4;
