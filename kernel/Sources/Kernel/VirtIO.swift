// VirtIO Common Driver for SwiftOS

import CSupport

let VIRTIO_PCI_VENDOR: UInt16 = 0x1AF4

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

struct VirtioConfig {
    var common: UnsafeMutablePointer<VirtioPciCommonCfg>?
    var notify: UnsafeMutableRawPointer?
    var isr: UnsafeMutableRawPointer?
    var device: UnsafeMutableRawPointer?
    var notify_off_multiplier: UInt32 = 0
}

func scanPci(vendor: UInt16, device: UInt16) -> (UInt8, UInt8, UInt8)? {
    for slot in 0..<32 {
        let v = pciRead16(bus: 0, slot: UInt8(slot), funcNum: 0, offset: 0)
        if v == 0xFFFF { continue }
        let d = pciRead16(bus: 0, slot: UInt8(slot), funcNum: 0, offset: 2)

        kprint("  PCI 00:")
        kprint_hex(UInt64(slot))
        kprint(" - ")
        kprint_hex(UInt64(v))
        kprint(":")
        kprint_hex(UInt64(d))
        kprint("\n")

        if v == vendor && d == device {
            return (0, UInt8(slot), 0)
        }
    }
    return nil
}

func parseVirtioCapabilities(dev: (UInt8, UInt8, UInt8), config: inout VirtioConfig) {
    var capOffset = pciRead8(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: 0x34)
    while capOffset != 0 {
        let capId = pciRead8(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset)
        if capId == 0x09 {  // Vendor Specific
            let type = pciRead8(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset + 3)
            let barIdx = pciRead8(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset + 4)
            let offset = pciRead32(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset + 8)

            let barRaw = pciRead32(
                bus: dev.0, slot: dev.1, funcNum: dev.2, offset: 0x10 + (barIdx * 4))
            let isIO = (barRaw & 1) != 0
            let barAddr = barRaw & 0xFFFF_FFF0
            let addr = UnsafeMutableRawPointer(bitPattern: UInt(barAddr + offset))

            kprint("    Cap: Type=")
            kprint_hex(UInt64(type))
            kprint(" BAR=")
            kprint_hex(UInt64(barIdx))
            kprint(isIO ? " (IO)" : " (Mem)")
            kprint(" Addr=")
            if let a = addr { kprint_hex(UInt64(UInt(bitPattern: a))) } else { kprint("NULL") }
            kprint("\n")

            switch type {
            case VIRTIO_PCI_CAP_COMMON_CFG:
                config.common = addr?.assumingMemoryBound(to: VirtioPciCommonCfg.self)
            case VIRTIO_PCI_CAP_NOTIFY_CFG:
                config.notify = addr
                config.notify_off_multiplier = pciRead32(
                    bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset + 16)
            case VIRTIO_PCI_CAP_ISR_CFG:
                config.isr = addr
            case VIRTIO_PCI_CAP_DEVICE_CFG:
                config.device = addr
            default:
                break
            }
        }
        capOffset = pciRead8(bus: dev.0, slot: dev.1, funcNum: dev.2, offset: capOffset + 1)
    }
}

func pciRead8(bus: UInt8, slot: UInt8, funcNum: UInt8, offset: UInt8) -> UInt8 {
    return UInt8(pci_config_read(bus, slot, funcNum, offset) >> ((offset % 4) * 8) & 0xFF)
}

func pciRead16(bus: UInt8, slot: UInt8, funcNum: UInt8, offset: UInt8) -> UInt16 {
    return UInt16(pci_config_read(bus, slot, funcNum, offset) >> ((offset % 4) * 8) & 0xFFFF)
}

func pciRead32(bus: UInt8, slot: UInt8, funcNum: UInt8, offset: UInt8) -> UInt32 {
    return pci_config_read(bus, slot, funcNum, offset)
}

func pciWrite16(bus: UInt8, slot: UInt8, funcNum: UInt8, offset: UInt8, value: UInt16) {
    let old = pci_config_read(bus, slot, funcNum, offset & ~3)
    let shift = (offset % 4) * 8
    let mask: UInt32 = ~(0xFFFF << shift)
    let new = (old & mask) | (UInt32(value) << shift)
    pci_config_write(bus, slot, funcNum, offset & ~3, new)
}

@_silgen_name("pci_config_read") func pci_config_read(
    _ bus: UInt8, _ slot: UInt8, _ funcNum: UInt8, _ offset: UInt8
) -> UInt32

@_silgen_name("pci_config_write") func pci_config_write(
    _ bus: UInt8, _ slot: UInt8, _ funcNum: UInt8, _ offset: UInt8, _ value: UInt32)

// Virtqueue structures

struct VirtqDesc {
    var addr: UInt64
    var len: UInt32
    var flags: UInt16
    var next: UInt16
}

struct VirtqAvail {
    var flags: UInt16
    var idx: UInt16
    // var ring: [UInt16]
}

struct VirtqUsedElem {
    var id: UInt32
    var len: UInt32
}

struct VirtqUsed {
    var flags: UInt16
    var idx: UInt16
    // var ring: [VirtqUsedElem]
}

let VIRTQ_DESC_F_NEXT: UInt16 = 1
let VIRTQ_DESC_F_WRITE: UInt16 = 2
let VIRTQ_DESC_F_INDIRECT: UInt16 = 4
