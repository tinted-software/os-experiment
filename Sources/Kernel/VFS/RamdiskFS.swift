/*
 * RamdiskFS.swift
 * Read-only file system for the initramfs (CPIO/Tar)
 */

import CSupport

class RamdiskFileNode: VNode {
    let type: VNodeType = .file
    let name: String
    let parent: VNode?
    let size: UInt64
    let data: UnsafeRawPointer

    init(name: String, parent: VNode?, size: UInt64, data: UnsafeRawPointer) {
        self.name = name
        self.parent = parent
        self.size = size
        self.data = data
    }

    func lookup(name: String) -> VNode? { return nil }
    func readdir() -> [String] { return [] }

    func read(offset: UInt64, count: Int, buffer: UnsafeMutableRawPointer) -> Int {
        if offset >= size { return 0 }
        let bytesToRead = min(Int(size - offset), count)
        memcpy(buffer, data.advanced(by: Int(offset)), bytesToRead)
        return bytesToRead
    }

    func write(offset: UInt64, count: Int, buffer: UnsafeRawPointer) -> Int { return -1 }  // Read-only
    func mmap(offset: UInt64, size: Int) -> UnsafeRawPointer? {
        // Return direct pointer from ramdisk memory
        if offset >= self.size { return nil }
        return data.advanced(by: Int(offset))
    }
    func close() {}
}

class RamdiskDirectoryNode: VNode {
    let type: VNodeType = .directory
    let name: String
    let parent: VNode?
    var children: [(String, VNode)] = []

    var size: UInt64 { return 0 }

    init(name: String, parent: VNode?) {
        self.name = name
        self.parent = parent
    }

    func lookup(name: String) -> VNode? {
        for child in children {
            if child.0 == name { return child.1 }
        }
        return nil
    }

    func readdir() -> [String] {
        return children.map { $0.0 }
    }

    func read(offset: UInt64, count: Int, buffer: UnsafeMutableRawPointer) -> Int { return -1 }
    func write(offset: UInt64, count: Int, buffer: UnsafeRawPointer) -> Int { return -1 }
    func mmap(offset: UInt64, size: Int) -> UnsafeRawPointer? { return nil }
    func close() {}
}

class RamdiskFS {
    let root: RamdiskDirectoryNode

    init(start: UnsafeRawPointer, size: Int) {
        self.root = RamdiskDirectoryNode(name: "", parent: nil)
        parseCPIO(start: start, size: size)
    }

    private func parseCPIO(start: UnsafeRawPointer, size: Int) {
        var offset = 0
        while offset < size {
            if offset + MemoryLayout<cpio_newc_header>.size > size { break }

            let headerPtr = start.advanced(by: offset)
            let header = headerPtr.assumingMemoryBound(to: cpio_newc_header.self).pointee

            // Magic check 070701
            if header.c_magic.0 != 0x30 || header.c_magic.1 != 0x37 {
                break
            }

            let namesize = parseHex8(header.c_namesize)
            let filesize = parseHex8(header.c_filesize)

            if namesize == 0 { break }

            let namePtr = headerPtr.advanced(by: MemoryLayout<cpio_newc_header>.size)
            var name = ""
            for i in 0..<namesize - 1 {
                let c = namePtr.load(fromByteOffset: i, as: UInt8.self)
                if c != 0 {
                    name.append(Character(UnicodeScalar(c)))
                }
            }

            let headerPlusName = MemoryLayout<cpio_newc_header>.size + namesize
            let alignedHeaderPlusName = (headerPlusName + 3) & ~3
            let fileDataPtr = headerPtr.advanced(by: alignedHeaderPlusName)

            if name == "TRAILER!!!" { break }

            let mode = parseHex8(header.c_mode)
            if (mode & 0x8000) != 0 {
                let node = RamdiskFileNode(
                    name: name, parent: root, size: UInt64(filesize), data: fileDataPtr)
                root.children.append((name, node))
            }

            let nextOffset = alignedHeaderPlusName + filesize
            offset += (nextOffset + 3) & ~3
        }
    }

    private func parseHex8(_ tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8))
        -> Int
    {
        var str = ""
        str.append(Character(UnicodeScalar(tuple.0)))
        str.append(Character(UnicodeScalar(tuple.1)))
        str.append(Character(UnicodeScalar(tuple.2)))
        str.append(Character(UnicodeScalar(tuple.3)))
        str.append(Character(UnicodeScalar(tuple.4)))
        str.append(Character(UnicodeScalar(tuple.5)))
        str.append(Character(UnicodeScalar(tuple.6)))
        str.append(Character(UnicodeScalar(tuple.7)))
        return Int(str, radix: 16) ?? 0
    }
}
