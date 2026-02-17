const std = @import("std");
const main = @import("main.zig");
const virtio = @import("virtio.zig");
const pmm = @import("pmm.zig");

pub const VIRTIO_PCI_DEVICE_BLOCK: u16 = 0x1001;

pub const VIRTIO_BLK_T_IN: u32 = 0;
pub const VIRTIO_BLK_T_OUT: u32 = 1;

pub const VirtioBlkOuthdr = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
};

pub const VirtioBlkDevice = struct {
    config: virtio.VirtioConfig,
    queue_size: u16,
    desc: [*]virtio.VirtqDesc,
    avail: *virtio.VirtqAvail,
    used: *virtio.VirtqUsed,
    last_used_idx: u16 = 0,
};

var device: ?VirtioBlkDevice = null;

pub fn init() void {
    main.kprint("Block Probe\n");
    const pci_dev = virtio.scanPci(virtio.VIRTIO_PCI_VENDOR, VIRTIO_PCI_DEVICE_BLOCK) orelse {
        main.kprint("Block NOT FOUND\n");
        return;
    };
    main.kprint("Block Found\n");

    // Enable PCI Bus Master and Memory Space
    const cmd = virtio.pciRead16(pci_dev.bus, pci_dev.slot, pci_dev.func, 4);
    virtio.pciWrite16(pci_dev.bus, pci_dev.slot, pci_dev.func, 4, cmd | 0x7);

    var config = virtio.VirtioConfig{};
    virtio.parseCapabilities(pci_dev, &config);

    if (config.common) |common| {
        main.kprint("Block Init\n");
        common.device_status = 0; // Reset
        common.device_status |= 1; // Acknowledge
        common.device_status |= 2; // Driver

        common.device_status |= 8; // FEATURES_OK

        common.queue_select = 0;
        const q_size = common.queue_size;
        main.kprint("  Queue Size: ");
        main.kprintHex(q_size);
        main.kprint("\n");

        // Simple allocation for virtqueue (Desc + Avail + Used)
        // Desc: 16 bytes * q_size
        // Avail: 6 bytes + 2 * q_size
        // Used: 6 bytes + 8 * q_size
        const vq_size = (16 * @as(usize, q_size) + 4095) & ~@as(usize, 4095);
        const avail_size = (6 + 2 * @as(usize, q_size) + 4095) & ~@as(usize, 4095);
        const used_size = (6 + 8 * @as(usize, q_size) + 4095) & ~@as(usize, 4095);

        const desc_phys = pmm.allocateFrames((vq_size + avail_size + used_size) / 4096) orelse return;
        const avail_phys = desc_phys + vq_size;
        const used_phys = avail_phys + avail_size;

        common.queue_desc = desc_phys;
        common.queue_driver = avail_phys;
        common.queue_device = used_phys;
        common.queue_enable = 1;

        common.device_status |= 128; // DRIVER_OK
        main.kprint("Block READY\n");

        device = VirtioBlkDevice{
            .config = config,
            .queue_size = q_size,
            .desc = @ptrFromInt(desc_phys),
            .avail = @ptrFromInt(avail_phys),
            .used = @ptrFromInt(used_phys),
        };
    }
}

pub fn read(sector: u64, count: u32, buffer: [*]u8) bool {
    const dev = device orelse return false;
    
    // We need some memory for the header and status
    // For now, let's use a static buffer or temporary frames
    // SwiftOS used kernelAlloc. Here we'll use some space near the end of our identity map or just a static buffer.
    // Let's use a static buffer for simplicity in this prototype.
    const Request = struct {
        hdr: VirtioBlkOuthdr align(16),
        status: u8 align(16),
    };
    var req: Request = undefined;
    req.hdr.type = VIRTIO_BLK_T_IN;
    req.hdr.reserved = 0;
    req.hdr.sector = sector;
    req.status = 0xFF;

    dev.desc[0].addr = @intFromPtr(&req.hdr);
    dev.desc[0].len = @sizeOf(VirtioBlkOuthdr);
    dev.desc[0].flags = virtio.VIRTQ_DESC_F_NEXT;
    dev.desc[0].next = 1;

    dev.desc[1].addr = @intFromPtr(buffer);
    dev.desc[1].len = count * 512;
    dev.desc[1].flags = virtio.VIRTQ_DESC_F_NEXT | virtio.VIRTQ_DESC_F_WRITE;
    dev.desc[1].next = 2;

    dev.desc[2].addr = @intFromPtr(&req.status);
    dev.desc[2].len = 1;
    dev.desc[2].flags = virtio.VIRTQ_DESC_F_WRITE;
    dev.desc[2].next = 0;

    const ring: [*]u16 = @ptrFromInt(@intFromPtr(dev.avail) + 4);
    ring[dev.avail.idx % dev.queue_size] = 0;

    asm volatile ("" ::: "memory");
    dev.avail.idx +%= 1;
    asm volatile ("" ::: "memory");

    if (dev.config.notify) |notify| {
        if (dev.config.common) |common| {
            common.queue_select = 0;
            const off = common.queue_notify_off * dev.config.notify_off_multiplier;
            notify[off] = 0; // Queue index
        }
    }

    var timeout: usize = 10_000_000;
    while (dev.used.idx == dev.last_used_idx and timeout > 0) : (timeout -= 1) {
        asm volatile ("pause");
    }

    if (timeout == 0) {
        main.kprint("Block Read TIMEOUT\n");
        return false;
    }

    device.?.last_used_idx = dev.used.idx;
    return req.status == 0;
}
