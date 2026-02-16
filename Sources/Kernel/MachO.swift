import CSupport

// MARK: - Mach-O Constants

let MH_MAGIC_64: UInt32 = 0xFEED_FACF
let FAT_MAGIC: UInt32 = 0xCAFE_BABE
let FAT_CIGAM: UInt32 = 0xBEBA_FECA

let CPU_TYPE_X86_64: UInt32 = 0x0100_0007  // CPU_TYPE_X86 | CPU_ARCH_ABI64

let LC_SEGMENT_64: UInt32 = 0x19
let LC_MAIN: UInt32 = 0x8000_0028
let LC_LOAD_DYLINKER: UInt32 = 0x0E
let LC_UNIXTHREAD: UInt32 = 0x05

let MH_EXECUTE: UInt32 = 2
let MH_DYLINKER: UInt32 = 7

// MARK: - Shared Cache Structures

struct DyldCacheHeader {
    // magic is "dyld_v1    x86_64" etc
    var magic:
        (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8
        )
    var mappingOffset: UInt32
    var mappingCount: UInt32
    var imagesOffset: UInt32
    var imagesCount: UInt32
    var dyldBaseAddress: UInt64
}

struct DyldCacheMappingInfo {
    var address: UInt64
    var size: UInt64
    var fileOffset: UInt64
    var maxProt: UInt32
    var initProt: UInt32
}

func loadSharedCache() {
    kprint("Shared Cache: Loading...\n")

    // Read header (sector 2048 = 1MB)
    let headerAddr = kernelAlloc(size: 512)
    if !virtioBlockRead(sector: 2048, count: 1, buffer: headerAddr) {
        kprint("Shared Cache: Failed to read header\n")
        return
    }

    let magic = headerAddr.assumingMemoryBound(to: UInt8.self)
    // Check "dyld_v1"
    if magic[0] != 0x64 || magic[1] != 0x79 || magic[2] != 0x6C || magic[3] != 0x64 {
        kprint("Shared Cache: Invalid magic\n")
        return
    }

    kprint("Shared Cache Header: ptr=")
    kprint_hex(UInt64(UInt(bitPattern: headerAddr)))
    kprint("\n  Header Data: ")
    for i in 0..<32 {
        kprint_hex(UInt64(headerAddr.load(fromByteOffset: i, as: UInt8.self)))
        if i % 8 == 7 { kprint(" ") }
    }
    kprint("\n")

    let mappingOffset = readU32(headerAddr.advanced(by: 16))
    let mappingCount = readU32(headerAddr.advanced(by: 20))

    kprint("Shared Cache Fields: Off=")
    kprint_hex(UInt64(mappingOffset))
    kprint(" Count=")
    kprint_hex(UInt64(mappingCount))
    kprint("\n")

    if mappingCount == 0 || mappingCount > 2000 {
        kprint("Shared Cache: Invalid mapping count criteria failed\n")
        return
    }

    kprint("Shared Cache: ")
    kprint_hex(UInt64(mappingCount))
    kprint(" mappings\n")

    // Read mapping info (it's usually right after header in the first few blocks)
    let mappingsAddr = kernelAlloc(size: Int(mappingCount) * 32)
    let mappingSectors = (Int(mappingCount) * 32 + 511) / 512
    if !virtioBlockRead(
        sector: 2048 + UInt64(mappingOffset / 512), count: mappingSectors, buffer: mappingsAddr)
    {
        kprint("Shared Cache: Failed to read mappings\n")
        return
    }

    var ptr = mappingsAddr
    for _ in 0..<Int(mappingCount) {
        let addr = readU64(ptr)
        let size = readU64(ptr.advanced(by: 8))

        kprint("  Map -> ")
        kprint_hex(addr)
        kprint(" size=")
        kprint_hex(size)
        kprint("\n")

        ptr = ptr.advanced(by: 32)
    }

    kprint("Shared Cache: Verified\n")
}

// MARK: - Unaligned Read Helpers
// CPIO data in the ramdisk may not be aligned, so we must use memcpy

func readU32(_ p: UnsafeRawPointer) -> UInt32 {
    var v: UInt32 = 0
    memcpy(&v, p, 4)
    return v
}

func readU64(_ p: UnsafeRawPointer) -> UInt64 {
    var v: UInt64 = 0
    memcpy(&v, p, 8)
    return v
}

// MARK: - Load Result

struct MachOLoadResult {
    var entryPoint: UInt64
    var textBase: UInt64
    var stackSize: UInt64
    var dylinkerPath: UnsafePointer<UInt8>?
    var dylinkerPathLen: Int
}

// MARK: - Segment Name Check

func segNameIs(_ p: UnsafeRawPointer, _ name: StaticString) -> Bool {
    // segname is at offset 8 in the segment command (after cmd + cmdsize)
    let seg = p.advanced(by: 8).assumingMemoryBound(to: UInt8.self)
    let n = name.utf8Start
    for i in 0..<name.utf8CodeUnitCount {
        if seg[i] != n[i] { return false }
    }
    if name.utf8CodeUnitCount < 16 {
        return seg[name.utf8CodeUnitCount] == 0
    }
    return true
}

// MARK: - FAT Binary Handling

func findX86_64Slice(data: UnsafeRawPointer, size: Int) -> (UnsafeRawPointer, Int)? {
    let magic = readU32(data)

    if magic == MH_MAGIC_64 {
        return (data, size)
    }

    if magic == FAT_MAGIC || magic == FAT_CIGAM {
        let shouldSwap = (magic == FAT_CIGAM)
        let nArch =
            shouldSwap ? readU32(data.advanced(by: 4)).byteSwapped : readU32(data.advanced(by: 4))
        var archPtr = data.advanced(by: 8)

        for _ in 0..<Int(nArch) {
            let cpuType = shouldSwap ? readU32(archPtr).byteSwapped : readU32(archPtr)
            if cpuType == CPU_TYPE_X86_64 {
                let off =
                    shouldSwap
                    ? readU32(archPtr.advanced(by: 8)).byteSwapped
                    : readU32(archPtr.advanced(by: 8))
                let sz =
                    shouldSwap
                    ? readU32(archPtr.advanced(by: 12)).byteSwapped
                    : readU32(archPtr.advanced(by: 12))
                return (data.advanced(by: Int(off)), Int(sz))
            }
            archPtr = archPtr.advanced(by: 20)  // sizeof(fat_arch)
        }
    }

    return nil
}

// MARK: - Mach-O Loader

func loadMachO(data: UnsafeRawPointer, size: Int, slide: UInt64 = 0) -> MachOLoadResult? {
    guard let (machData, _) = findX86_64Slice(data: data, size: size) else {
        kprint("MachO: No x86_64 slice found\n")
        return nil
    }

    let magic = readU32(machData)
    guard magic == MH_MAGIC_64 else {
        kprint("MachO: Bad magic\n")
        return nil
    }

    // mach_header_64 layout: magic(4), cputype(4), cpusubtype(4), filetype(4),
    //                        ncmds(4), sizeofcmds(4), flags(4), reserved(4) = 32 bytes
    let ncmds = readU32(machData.advanced(by: 16))

    kprint("MachO: ptr=")
    kprint_hex(UInt64(UInt(bitPattern: machData)))
    kprint(" magic=")
    kprint_hex(UInt64(magic))
    kprint("\n")

    // Hex dump first 32 bytes of header
    kprint("  Header: ")
    for i in 0..<32 {
        kprint_hex(UInt64(machData.load(fromByteOffset: i, as: UInt8.self)))
        if i % 8 == 7 { kprint(" ") }
    }
    kprint("\n")

    kprint("MachO: Loading (")
    kprint_hex(UInt64(ncmds))
    kprint(" cmds)\n")

    var entryIsRelative = false
    var result = MachOLoadResult(
        entryPoint: 0,
        textBase: 0,
        stackSize: 0x100000,
        dylinkerPath: nil,
        dylinkerPathLen: 0
    )

    var cmdPtr = machData.advanced(by: 32)  // sizeof(mach_header_64)

    for _ in 0..<Int(ncmds) {
        let cmd = readU32(cmdPtr)
        let cmdsize = readU32(cmdPtr.advanced(by: 4))

        kprint("  LC: ")
        kprint_hex(UInt64(cmd))
        kprint(" sz=")
        kprint_hex(UInt64(cmdsize))
        kprint("\n")

        switch cmd {
        case LC_SEGMENT_64:
            // segment_command_64 layout:
            // cmd(4), cmdsize(4), segname(16), vmaddr(8), vmsize(8),
            // fileoff(8), filesize(8), maxprot(4), initprot(4), nsects(4), flags(4)
            let vmaddr = readU64(cmdPtr.advanced(by: 24))
            let vmsize = readU64(cmdPtr.advanced(by: 32))
            let fileoff = readU64(cmdPtr.advanced(by: 40))
            let filesize = readU64(cmdPtr.advanced(by: 48))

            // Skip __PAGEZERO
            if segNameIs(cmdPtr, "__PAGEZERO") {
                break
            }

            // Record __TEXT base
            if segNameIs(cmdPtr, "__TEXT") {
                result.textBase = vmaddr
            }

            // Map segment
            if vmsize > 0 {
                let destAddr = UInt(vmaddr) &+ UInt(slide)
                if let dest = UnsafeMutableRawPointer(bitPattern: destAddr) {
                    memset(dest, 0, Int(vmsize))
                    if filesize > 0 {
                        let src = machData.advanced(by: Int(fileoff))
                        memcpy(dest, src, Int(filesize))
                    }
                    kprint("  Seg -> ")
                    kprint_hex(UInt64(destAddr))
                    kprint(" +")
                    kprint_hex(vmsize)
                    kprint("\n")
                }
            }

        case LC_MAIN:
            // entry_point_command: cmd(4), cmdsize(4), entryoff(8), stacksize(8)
            result.entryPoint = readU64(cmdPtr.advanced(by: 8))
            entryIsRelative = true
            let stacksize = readU64(cmdPtr.advanced(by: 16))
            if stacksize > 0 { result.stackSize = stacksize }

        case LC_UNIXTHREAD:
            // thread_command: cmd(4), cmdsize(4), flavor(4), count(4), state...
            let flavor = readU32(cmdPtr.advanced(by: 8))
            kprint("    UnixThread: flavor=")
            kprint_hex(UInt64(flavor))
            kprint("\n")

            if flavor == 4 {  // x86_THREAD_STATE64
                // RIP is at offset 144 (cmd:4, sz:4, flavor:4, count:4, rax..r15:128)
                let rip = readU64(cmdPtr.advanced(by: 144))
                result.entryPoint = rip
                kprint("      RIP -> ")
                kprint_hex(rip)
                kprint("\n")
            }

        case LC_LOAD_DYLINKER:
            // dylinker_command: cmd(4), cmdsize(4), name_offset(4)
            let nameOff = readU32(cmdPtr.advanced(by: 8))
            let pathPtr = cmdPtr.advanced(by: Int(nameOff)).assumingMemoryBound(to: UInt8.self)
            result.dylinkerPath = pathPtr
            var len = 0
            while len < Int(cmdsize) - Int(nameOff) && pathPtr[len] != 0 {
                len += 1
            }
            result.dylinkerPathLen = len
            kprint("    Dylinker: ")
            for i in 0..<len { serial_putc(pathPtr[i]) }
            kprint("\n")

        default:
            break
        }

        cmdPtr = cmdPtr.advanced(by: Int(cmdsize))
    }

    // LC_MAIN: entryoff is relative to __TEXT
    if entryIsRelative {
        result.entryPoint = result.entryPoint &+ result.textBase &+ slide
    } else {
        // LC_UNIXTHREAD: RIP is absolute, just add slide
        result.entryPoint = result.entryPoint &+ slide
    }

    return result
}
