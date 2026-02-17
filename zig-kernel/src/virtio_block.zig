const virtio = @import("virtio.zig");

extern fn asm_pause() void;
extern fn asm_volatile_barrier() void;
extern fn kernel_alloc(size: usize, alignment: usize) ?*u8;

const VIRTIO_PCI_DEVICE_BLOCK: u16 = 0x1001;

const VIRTIO_BLK_T_IN: u32 = 0;
const VIRTIO_BLK_T_OUT: u32 = 1;

const VirtioBlkOuthdr = extern struct {
    typ: u32,
    reserved: u32,
    sector: u64,
};

const VirtioBlkStatus = extern struct { status: u8 };

const VirtioBlkDevice = struct {
    config: virtio.VirtioConfig,
    queueSize: usize,
    desc: ?*virtio.VirtqDesc,
    avail: ?*virtio.VirtqAvail,
    used: ?*virtio.VirtqUsed,
    lastUsedIdx: u16,
};

pub var blockDevice: ?*VirtioBlkDevice = null;

pub fn initVirtioBlock() void {
    // Probe
    const dev = virtio.scanPci(virtio.VIRTIO_PCI_VENDOR, VIRTIO_PCI_DEVICE_BLOCK) orelse return;

    // Enable PCI Command register: IO, Mem, Bus Master
    const cmd = virtio.pciRead16(dev.bus, dev.slot, dev.func, 4);
    virtio.pciWrite16(dev.bus, dev.slot, dev.func, 4, cmd | 0x7);

    var config: virtio.VirtioConfig = .{ .common = null, .notify = null, .isr = null, .device = null, .notify_off_multiplier = 0 };
    virtio.parseVirtioCapabilities(dev, &config);

    if (config.common) |common| {
        // Reset and driver handshake
        common.*.device_status = 0;
        common.*.device_status |= 1; // ACK
        common.*.device_status |= 2; // DRIVER
        common.*.device_status |= 8; // FEATURES_OK

        common.*.queue_select = 0;
        const qSize: usize = @intCast(common.*.queue_size);

        // Allocate virtqueue backing memory (desc + avail + used) with alignment
        const desc_bytes = qSize * 16;
        // const avail_bytes = 8 + qSize * 2;
        const used_bytes = 8 + qSize * 8;
        const vq_size = ((desc_bytes + 8 + qSize * 2 + 4095) & ~4095) + ((used_bytes + 4095) & ~4095);

        const rawPtr = kernel_alloc(vq_size, 4096) orelse return;

        const descPtr: *virtio.VirtqDesc = @ptrCast(rawPtr);
        const availPtr: *virtio.VirtqAvail = @ptrCast(@as(*virtio.VirtqAvail, @ptrFromInt(@intFromPtr(rawPtr) + desc_bytes)));
        const usedPtr: *virtio.VirtqUsed = @ptrCast(@as(*virtio.VirtqUsed, @ptrFromInt(@intFromPtr(rawPtr) + ((desc_bytes + 8 + qSize * 2 + 4095) & ~4095))));

        common.*.queue_desc = @as(u64, @intFromPtr(descPtr));
        common.*.queue_driver = @as(u64, @intFromPtr(availPtr));
        common.*.queue_device = @as(u64, @intFromPtr(usedPtr));
        common.*.queue_enable = 1;

        common.*.device_status |= 128; // DRIVER_OK

        // Allocate device struct storage
        const dev_ptr = kernel_alloc(@sizeOf(VirtioBlkDevice), 16) orelse return;
        const dev_struct: *VirtioBlkDevice = @ptrCast(dev_ptr);
        dev_struct.* = VirtioBlkDevice{ .config = config, .queueSize = qSize, .desc = descPtr, .avail = availPtr, .used = usedPtr, .lastUsedIdx = 0 };
        blockDevice = dev_struct;
    }
}

pub fn virtioBlockRead(sector: u64, count: usize, buffer: *u8) bool {
    if (count == 0) return true;
    const dev = blockDevice orelse return false;
    const d = dev.*;
    const qSize = d.queueSize;
    const descs = d.desc orelse return false;
    const avail = d.avail orelse return false;

    const hdr_ptr = kernel_alloc(@sizeOf(VirtioBlkOuthdr), 16) orelse return false;
    const status_ptr = kernel_alloc(1, 1) orelse return false;
    const hdr: *virtio.VirtioBlkOuthdr = @ptrCast(hdr_ptr);
    const status: *u8 = @ptrCast(status_ptr);

    hdr.* = VirtioBlkOuthdr{ .typ = VIRTIO_BLK_T_IN, .reserved = 0, .sector = sector };
    status.* = 0xFF;

    descs[0].addr = @as(u64, @intFromPtr(hdr));
    descs[0].len = @as(u32, @sizeOf(VirtioBlkOuthdr));
    descs[0].flags = virtio.VIRTQ_DESC_F_NEXT;
    descs[0].next = 1;

    descs[1].addr = @as(u64, @intFromPtr(buffer));
    descs[1].len = @as(u32, count * 512);
    descs[1].flags = virtio.VIRTQ_DESC_F_NEXT | virtio.VIRTQ_DESC_F_WRITE;
    descs[1].next = 2;

    descs[2].addr = @as(u64, @intFromPtr(status));
    descs[2].len = 1;
    descs[2].flags = virtio.VIRTQ_DESC_F_WRITE;
    descs[2].next = 0;

    // Update avail ring: ring starts 4 bytes after avail struct
    const ring_ptr: [*]u16 = @ptrCast(@as([*]u16, @ptrFromInt(@intFromPtr(avail) + 4)));
    const availIdx: usize = @intCast(avail.*.idx % @as(u16, qSize));
    ring_ptr[availIdx] = 0; // head of descriptor chain

    asm_volatile_barrier();

    avail.*.idx = avail.*.idx + 1;

    // Notify
    if (d.config.notify) |notify_ptr| {
        if (d.config.common) |common_ptr| {
            common_ptr.*.queue_select = 0;
            const off = @as(usize, common_ptr.*.queue_notify_off) * @as(usize, d.config.notify_off_multiplier);
            const notify_addr: *u16 = @ptrCast(@as(*u16, @ptrFromInt(@intFromPtr(notify_ptr) + off)));
            notify_addr.* = 0;
        }
    }

    var timeout: usize = 10_000_000;
    while (d.used.*.idx == d.lastUsedIdx and timeout > 0) {
        asm_pause();
        timeout -= 1;
    }

    if (timeout == 0) {
        return false;
    }

    // update lastUsedIdx
    d.lastUsedIdx = d.used.*.idx;

    return status.* == 0;
}
