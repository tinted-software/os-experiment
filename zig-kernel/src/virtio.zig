const std = @import("std");

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
    common: ?*VirtioPciCommonCfg,
    notify: ?[*]u8,
    isr: ?[*]u8,
    device: ?[*]u8,
    notify_off_multiplier: u32,
};

pub const Dev = struct { bus: u8, slot: u8, func: u8 };

extern fn pci_config_read(bus: u8, slot: u8, func: u8, offset: u8) u32;
extern fn pci_config_write(bus: u8, slot: u8, func: u8, offset: u8, value: u32) void;

pub fn pciRead8(bus: u8, slot: u8, func: u8, offset: u8) u8 {
    return @intCast((pci_config_read(bus, slot, func, offset) >> ((offset % 4) * 8)) & 0xFF);
}

pub fn pciRead16(bus: u8, slot: u8, func: u8, offset: u8) u16 {
    return @intCast((pci_config_read(bus, slot, func, offset) >> ((offset % 4) * 8)) & 0xFFFF);
}

pub fn pciRead32(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    return pci_config_read(bus, slot, func, offset);
}

pub fn pciWrite16(bus: u8, slot: u8, func: u8, offset: u8, value: u16) void {
    const old = pci_config_read(bus, slot, func, offset & ~3);
    const shift = ((offset % 4) * 8);
    const mask: u32 = ~(@as(u32, 0xFFFF) << shift);
    const new = (old & mask) | (@as(u32, value) << shift);
    pci_config_write(bus, slot, func, offset & ~3, new);
}

pub fn scanPci(vendor: u16, device: u16) ?Dev {
    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        const v = pciRead16(0, slot, 0, 0);
        if (v == 0xFFFF) continue;
        const d = pciRead16(0, slot, 0, 2);
        // debug
        // kprint prints are in main
        if (v == vendor and d == device) {
            return Dev{ .bus = 0, .slot = slot, .func = 0 };
        }
    }
    return null;
}

pub fn parseVirtioCapabilities(dev: Dev, config: *VirtioConfig) void {
    var capOffset: u8 = pciRead8(dev.bus, dev.slot, dev.func, 0x34);
    while (capOffset != 0) : (capOffset = pciRead8(dev.bus, dev.slot, dev.func, capOffset + 1)) {
        const capId = pciRead8(dev.bus, dev.slot, dev.func, capOffset);
        if (capId == 0x09) {
            const typ = pciRead8(dev.bus, dev.slot, dev.func, capOffset + 3);
            const barIdx = pciRead8(dev.bus, dev.slot, dev.func, capOffset + 4);
            const off = pciRead32(dev.bus, dev.slot, dev.func, capOffset + 8);

            const barRaw = pciRead32(dev.bus, dev.slot, dev.func, 0x10 + (@as(u8, barIdx) * 4));
            // const isIO = ((barRaw & 1) != 0);
            const barAddr = barRaw & 0xFFFF_FFF0;
            const addr: usize = @intCast(barAddr + off);

            switch (typ) {
                VIRTIO_PCI_CAP_COMMON_CFG => config.common = @ptrCast(@as(?*VirtioPciCommonCfg, @ptrFromInt(addr))),
                VIRTIO_PCI_CAP_NOTIFY_CFG => {
                    config.notify = @ptrFromInt(addr);
                    config.notify_off_multiplier = pciRead32(dev.bus, dev.slot, dev.func, capOffset + 16);
                },
                VIRTIO_PCI_CAP_ISR_CFG => config.isr = @ptrFromInt(addr),
                VIRTIO_PCI_CAP_DEVICE_CFG => config.device = @ptrFromInt(addr),
                else => {},
            }
        }
    }
}

// Virtqueue structures
pub const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
};

pub const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};

pub const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
};

pub const VIRTQ_DESC_F_NEXT: u16 = 1;
pub const VIRTQ_DESC_F_WRITE: u16 = 2;
pub const VIRTQ_DESC_F_INDIRECT: u16 = 4;
