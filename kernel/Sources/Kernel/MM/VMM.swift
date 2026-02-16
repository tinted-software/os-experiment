/*
 * MM/VMM.swift
 * Virtual Memory Management
 */

import CSupport

// Global state for VMM
nonisolated(unsafe) private var pml4: UnsafeMutablePointer<UInt64>!

public struct VMM {
    public static func setup() {
        kprint("VMM setup\n")
        let cr3 = asm_get_cr3()
        let physPML4 = cr3 & ~0xFFF
        pml4 = UnsafeMutablePointer<UInt64>(bitPattern: UInt(physPML4))!
    }

    // Flags: 1=Present, 2=RW, 4=User
    public static func map(virt: UInt64, phys: PhysAddr, flags: UInt64) {
        let pml4Index = (virt >> 39) & 0x1FF
        let pdptIndex = (virt >> 30) & 0x1FF
        let pdIndex = (virt >> 21) & 0x1FF
        let ptIndex = (virt >> 12) & 0x1FF

        // PML4 -> PDPT
        guard let pdptPhys = getOrAllocTable(entry: &pml4[Int(pml4Index)]) else { return }
        let pdpt = UnsafeMutablePointer<UInt64>(bitPattern: UInt(pdptPhys))!

        // PDPT -> PD
        guard let pdPhys = getOrAllocTable(entry: &pdpt[Int(pdptIndex)]) else { return }
        let pd = UnsafeMutablePointer<UInt64>(bitPattern: UInt(pdPhys))!

        // PD -> PT
        guard let ptPhys = getOrAllocTable(entry: &pd[Int(pdIndex)], isL2: true) else { return }
        let pt = UnsafeMutablePointer<UInt64>(bitPattern: UInt(ptPhys))!

        // PT Entry
        pt[Int(ptIndex)] = phys.value | flags | 1  // Always Present
        asm_invlpg(UnsafeMutableRawPointer(bitPattern: UInt(virt)))
    }

    private static func getOrAllocTable(entry: UnsafeMutablePointer<UInt64>, isL2: Bool = false)
        -> UInt64?
    {
        var val = entry.pointee
        if (val & 1) == 0 {
            // Not present, allocate new table
            guard let frame = PMM.allocateFrame() else { return nil }
            // Default flags: User | RW | Present
            val = frame.value | 7
            entry.pointee = val
            return frame.value
        }

        // Check for Huge Page (Bit 7, value 0x80)
        if (val & 0x80) != 0 {
            if isL2 {
                return split2MBPage(entry: entry)
            }
            return nil
        }

        return val & ~0xFFF
    }

    private static func split2MBPage(entry: UnsafeMutablePointer<UInt64>) -> UInt64? {
        let hugePagePhys = entry.pointee & ~UInt64(0x1FFFFF)
        let hugePageFlags = entry.pointee & 0x1FF
        let ptFlags = hugePageFlags & ~UInt64(0x80)

        guard let frame = PMM.allocateFrame() else { return nil }
        let pt = UnsafeMutablePointer<UInt64>(bitPattern: UInt(frame.value))!

        for i in 0..<512 {
            pt[i] = (hugePagePhys + UInt64(i * 4096)) | ptFlags
        }

        // Update the PD entry to point to this new PT
        entry.pointee = frame.value | 7
        return frame.value
    }
}
