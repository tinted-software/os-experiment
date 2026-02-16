// VirtIO GPU Driver for SwiftOS

let VIRTIO_PCI_VENDOR: UInt16 = 0x1AF4
let VIRTIO_PCI_DEVICE_GPU: UInt16 = 0x1050

let VIRTIO_PCI_CAP_COMMON_CFG: UInt8 = 1
let VIRTIO_PCI_CAP_NOTIFY_CFG: UInt8 = 2
let VIRTIO_PCI_CAP_ISR_CFG: UInt8 = 3
let VIRTIO_PCI_CAP_DEVICE_CFG: UInt8 = 4

struct VirtioPciCommonCfg {
    var device_feature_select: UInt32
    var device_feature: UInt32
    var driver_feature_select: UInt32
    var driver_feature: UInt32
    var config_msix_vector: UInt16
    var num_queues: UInt16
    var device_status: UInt8
    var config_generation: UInt8
    var queue_select: UInt16
    var queue_size: UInt16
    var queue_msix_vector: UInt16
    var queue_enable: UInt16
    var queue_notify_off: UInt16
    var queue_desc: UInt64
    var queue_driver: UInt64
    var queue_device: UInt64
}

struct VirtioGpuConfig {
    var common: UnsafeMutablePointer<VirtioPciCommonCfg>?
    var notify: UnsafeMutableRawPointer?
    var isr: UnsafeMutableRawPointer?
    var device: UnsafeMutableRawPointer?
}

func initVirtioGpu() {
    kprint("GPU Probe\n")

    guard let dev = scanPci(vendor: VIRTIO_PCI_VENDOR, device: VIRTIO_PCI_DEVICE_GPU) else {
        kprint("GPU NOT FOUND\n")
        return
    }

    kprint("GPU Found\n")

    var config = VirtioGpuConfig()
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
        common.pointee.device_status |= 4  // FEATURES_OK

        // 5. Driver OK
        common.pointee.device_status |= 128
        kprint("GPU READY\n")
    }
}

private func scanPci(vendor: UInt16, device: UInt16) -> (UInt8, UInt8, UInt8)? {
    for slot in 0..<32 {
        let v = pciRead16(bus: 0, slot: UInt8(slot), funcNum: 0, offset: 0)
        if v == 0xFFFF { continue }
        let d = pciRead16(bus: 0, slot: UInt8(slot), funcNum: 0, offset: 2)
        if v == vendor && d == device {
            return (0, UInt8(slot), 0)
        }
    }
    return nil
}

private func parseVirtioCapabilities(dev: (UInt8, UInt8, UInt8), config: inout VirtioGpuConfig) {
    var capOffset = pciRead8(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: 0x34)
    while capOffset != 0 {
        let capId = pciRead8(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset)
        if capId == 0x09 {  // Vendor Specific
            let type = pciRead8(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset + 3)
            let barIdx = pciRead8(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset + 4)
            let offset = pciRead32(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset + 8)

            let barAddr =
                pciRead32(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: 0x10 + (barIdx * 4))
                & 0xFFFF_FFF0
            let addr = UnsafeMutableRawPointer(bitPattern: UInt(barAddr + offset))

            switch type {
            case VIRTIO_PCI_CAP_COMMON_CFG:
                config.common = addr?.assumingMemoryBound(to: VirtioPciCommonCfg.self)
            case VIRTIO_PCI_CAP_NOTIFY_CFG: config.notify = addr
            case VIRTIO_PCI_CAP_ISR_CFG: config.isr = addr
            case VIRTIO_PCI_CAP_DEVICE_CFG: config.device = addr
            default: break
            }
        }
        capOffset = pciRead8(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset + 1)
    }
}

private func pciRead8(bus: UInt8, slot: UInt8, funcNum: UInt8, offset: UInt8) -> UInt8 {
    return UInt8(pci_config_read(bus, slot, funcNum, offset) >> ((offset % 4) * 8) & 0xFF)
}

private func pciRead16(bus: UInt8, slot: UInt8, funcNum: UInt8, offset: UInt8) -> UInt16 {
    return UInt16(pci_config_read(bus, slot, funcNum, offset) >> ((offset % 4) * 8) & 0xFFFF)
}

private func pciRead32(bus: UInt8, slot: UInt8, funcNum: UInt8, offset: UInt8) -> UInt32 {
    return pci_config_read(bus, slot, funcNum, offset)
}

@_silgen_name("pci_config_read") func pci_config_read(
    _ bus: UInt8, _ slot: UInt8, _ funcNum: UInt8, _ offset: UInt8
) -> UInt32
