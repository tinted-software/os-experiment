/*
 * MM/PMM.swift
 * Physical Memory Manager
 */

import CSupport

public struct PhysAddr: Equatable {
    public var value: UInt64
    public init(_ value: UInt64) { self.value = value }
}

nonisolated(unsafe)  // Global state to avoid class initialization issues
    private var nextFree: UInt64 = 0x0800_0000
private let ramEnd: UInt64 = 0x2000_0000  // 512MB

public struct PMM {
    // Primitive Bump allocator for now.
    public static func allocateFrame() -> PhysAddr? {
        if nextFree >= ramEnd { return nil }
        let frame = nextFree
        nextFree += 4096
        // Clear frame content
        if let ptr = UnsafeMutableRawPointer(bitPattern: UInt(frame)) {
            memset(ptr, 0, 4096)
        }
        return PhysAddr(frame)
    }

    public static func allocateFrames(count: Int) -> PhysAddr? {
        let size = UInt64(count * 4096)
        if nextFree + size >= ramEnd { return nil }
        let frame = nextFree
        nextFree += size
        // Clear frame content
        if let ptr = UnsafeMutableRawPointer(bitPattern: UInt(frame)) {
            memset(ptr, 0, Int(size))
        }
        return PhysAddr(frame)
    }

    public static func freeFrame(_ frame: PhysAddr) {
        // Leak
    }
}
