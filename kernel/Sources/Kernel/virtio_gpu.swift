// VirtIO GPU Driver for SwiftOS

import CSupport

let VIRTIO_PCI_DEVICE_GPU: UInt16 = 0x1050

func initVirtioGpu() {
    kprint("GPU Probe\n")

    guard let dev = scanPci(vendor: VIRTIO_PCI_VENDOR, device: VIRTIO_PCI_DEVICE_GPU) else {
        kprint("GPU NOT FOUND\n")
        return
    }

    kprint("GPU Found\n")

    // Enable PCI Command register: IO Space (0), Memory Space (1), Bus Master (2)
    let cmd = pciRead16(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: 4)
    pciWrite16(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: 4, value: cmd | 0x7)

    var config = VirtioConfig()
    parseVirtioCapabilities(dev: dev, config: &config)

    if let common = config.common {
        kprint("GPU Init\n")
        // 1. Reset
        common.pointee.device_status = 0
        // 2. Acknowledge
        common.pointee.device_status |= 1
        // 3. Driver
        common.pointee.device_status |= 2

        // 4. Features (skip for now)
        common.pointee.device_status |= 8  // FEATURES_OK

        // 5. Driver OK
        common.pointee.device_status |= 128
        kprint("GPU READY\n")
    }
}
