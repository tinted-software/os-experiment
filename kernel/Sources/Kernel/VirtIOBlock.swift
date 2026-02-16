// VirtIO Block Driver for SwiftOS

import CSupport

let VIRTIO_PCI_DEVICE_BLOCK: UInt16 = 0x1001

let VIRTIO_BLK_T_IN: UInt32 = 0
let VIRTIO_BLK_T_OUT: UInt32 = 1

struct VirtioBlkOuthdr {
    var type: UInt32
    var reserved: UInt32
    var sector: UInt64
}

struct VirtioBlkStatus {
    var status: UInt8
}

struct VirtioBlkDevice {
    var config: VirtioConfig
    var queueSize: Int = 0
    var desc: UnsafeMutablePointer<VirtqDesc>?
    var avail: UnsafeMutablePointer<VirtqAvail>?
    var used: UnsafeMutablePointer<VirtqUsed>?
    var lastUsedIdx: UInt16 = 0
}

nonisolated(unsafe) var blockDevice: VirtioBlkDevice?

func initVirtioBlock() {
    kprint("Block Probe\n")

    guard let dev = scanPci(vendor: VIRTIO_PCI_VENDOR, device: VIRTIO_PCI_DEVICE_BLOCK) else {
        kprint("Block NOT FOUND\n")
        return
    }

    kprint("Block Found\n")

    // Enable PCI Command register: IO Space (0), Memory Space (1), Bus Master (2)
    let cmd = pciRead16(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: 4)
    pciWrite16(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: 4, value: cmd | 0x7)

    var config = VirtioConfig()
    parseVirtioCapabilities(dev: dev, config: &config)

    if let common = config.common {
        kprint("Block Init\n")
        // 1. Reset
        common.pointee.device_status = 0
        // 2. Acknowledge
        common.pointee.device_status |= 1
        // 3. Driver
        common.pointee.device_status |= 2

        // 4. Features (negotiate)
        // For now just accept what the device offers
        common.pointee.device_status |= 8  // FEATURES_OK

        // 5. Setup Virtqueue
        common.pointee.queue_select = 0
        let qSize = Int(common.pointee.queue_size)
        kprint("  Queue Size: ")
        kprint_hex(UInt64(qSize))
        kprint("\n")

        // Allocate space for the virtqueue
        let vq_size = (qSize * 16 + 8 + qSize * 2 + 4095) & ~4095 + (8 + qSize * 8 + 4095) & ~4095
        let rawPtr = kernelAlloc(size: vq_size, align: 4096)

        let descPtr = rawPtr.assumingMemoryBound(to: VirtqDesc.self)
        let availPtr = rawPtr.advanced(by: qSize * 16).assumingMemoryBound(to: VirtqAvail.self)
        let usedPtr = rawPtr.advanced(by: (qSize * 16 + 8 + qSize * 2 + 4095) & ~4095)
            .assumingMemoryBound(to: VirtqUsed.self)

        common.pointee.queue_desc = UInt64(UInt(bitPattern: descPtr))
        common.pointee.queue_driver = UInt64(UInt(bitPattern: availPtr))
        common.pointee.queue_device = UInt64(UInt(bitPattern: usedPtr))
        common.pointee.queue_enable = 1

        // 6. Driver OK
        common.pointee.device_status |= 128
        kprint("Block READY\n")

        blockDevice = VirtioBlkDevice(
            config: config,
            queueSize: qSize,
            desc: descPtr,
            avail: availPtr,
            used: usedPtr
        )
    }
}

func virtioBlockRead(sector: UInt64, count: Int, buffer: UnsafeMutableRawPointer) -> Bool {
    if count <= 0 { return true }  // Nothing to do
    guard let dev = blockDevice, let descs = dev.desc, let avail = dev.avail else { return false }

    // Allocate space for request headers at a safe location
    let hdr = kernelAlloc(size: MemoryLayout<VirtioBlkOuthdr>.size).assumingMemoryBound(
        to: VirtioBlkOuthdr.self)
    let status = kernelAlloc(size: 1).assumingMemoryBound(to: UInt8.self)

    hdr.pointee.type = VIRTIO_BLK_T_IN
    hdr.pointee.reserved = 0
    hdr.pointee.sector = sector
    status.pointee = 0xFF

    descs[0].addr = UInt64(UInt(bitPattern: hdr))
    descs[0].len = UInt32(MemoryLayout<VirtioBlkOuthdr>.size)
    descs[0].flags = VIRTQ_DESC_F_NEXT
    descs[0].next = 1

    descs[1].addr = UInt64(UInt(bitPattern: buffer))
    descs[1].len = UInt32(count * 512)
    descs[1].flags = VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE
    descs[1].next = 2

    descs[2].addr = UInt64(UInt(bitPattern: status))
    descs[2].len = 1
    descs[2].flags = VIRTQ_DESC_F_WRITE
    descs[2].next = 0

    // Update avail ring
    let availIdx = Int(avail.pointee.idx % UInt16(dev.queueSize))
    let ringPtr = UnsafeMutablePointer<UInt16>(bitPattern: UInt(bitPattern: avail) + 4)!
    ringPtr[availIdx] = 0  // Head of descriptor chain

    // Memory barrier
    asm_volatile_barrier()

    avail.pointee.idx = avail.pointee.idx &+ 1

    // Notify
    if let notify = dev.config.notify, let common = dev.config.common {
        common.pointee.queue_select = 0
        let off = UInt(common.pointee.queue_notify_off) * UInt(dev.config.notify_off_multiplier)
        let notifyPtr = (notify + Int(off)).assumingMemoryBound(to: UInt16.self)
        notifyPtr.pointee = 0  // Queue index
    }

    // Wait for completion (poll used ring)
    var timeout = 10_000_000
    while dev.used!.pointee.idx == blockDevice!.lastUsedIdx && timeout > 0 {
        asm_pause()
        timeout -= 1
    }

    if timeout == 0 {
        kprint("Block Read TIMEOUT\n")
        return false
    }

    blockDevice?.lastUsedIdx = dev.used!.pointee.idx

    return status.pointee == 0
}
