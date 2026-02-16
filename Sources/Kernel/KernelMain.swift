/*
 * KernelMain.swift
 * SwiftOS Kernel Entry Point
 */

import CSupport

// Global bump allocator state
nonisolated(unsafe) public var nextKernelAddr: UInt64 = 0x100000 + 4096 * 16  // After 1MB + 64KB stack

@_cdecl("kernel_alloc")
public func kernelAlloc(size: Int, align: Int = 16) -> UnsafeMutableRawPointer {
    let aligned = (nextKernelAddr + UInt64(align) - 1) & ~(UInt64(align) - 1)
    nextKernelAddr = aligned + UInt64(size)
    return UnsafeMutableRawPointer(bitPattern: UInt(aligned))!
}

@_cdecl("kmain")
public func kmain(magic: UInt32, infoAddr: UInt32) {
    serial_init()
    kprint("SwiftOS Kernel Booting...\n")

    kprint("Magic: ")
    kprint_hex(UInt64(magic))
    kprint("\n")

    if magic != 0x36d7_6289 && magic != 0x2BAD_B002 {
        kprint("Error: Invalid Multiboot magic\n")
        return
    }

    // Capture stack top (offset from Multiboot info or hardcoded)
    let stackAddr = get_stack_top()
    kprint("Stack Top: ")
    kprint_hex(stackAddr)
    kprint("\n")

    // Setup FSGSBASE
    enable_fsgsbase()

    // Initialize GDT/TSS
    setup_gdt_tss(stackAddr)

    // Setup IDT
    setup_idt()

    // Setup Syscall MSRs
    setup_syscall_msrs()

    initVirtioGpu()
    initVirtioBlock()
    VMM.setup()

    // Parse Multiboot info to find ramdisk
    let info = UnsafePointer<MultibootInfo>(bitPattern: UInt(infoAddr))!.pointee
    if (info.flags & (1 << 3)) == 0 || info.mods_count == 0 {
        kprint("Error: No ramdisk found\n")
        while true { asm_hlt() }
    }
    let mod = UnsafePointer<MultibootModule>(bitPattern: UInt(info.mods_addr))!.pointee
    let rdStart = UnsafeRawPointer(bitPattern: UInt(mod.mod_start))!
    let rdSize = Int(mod.mod_end - mod.mod_start)
    kprint("Ramdisk: ")
    kprint_hex(UInt64(mod.mod_start))
    kprint(" size=")
    kprint_hex(UInt64(rdSize))
    kprint("\n")

    // Find dyld in ramdisk
    if let (dyldData, dyldSize) = findFile(
        in: rdStart, size: rdSize, named: "usr/lib/dyld")
    {
        kprint("Found dyld: size=")
        kprint_hex(UInt64(dyldSize))
        kprint("\n")

        kprint("Loading dyld...\n")
        if let dyldResult = loadMachO(data: dyldData, size: dyldSize, slide: 0x1000_0000) {
            kprint("dyld loaded. Entry: ")
            kprint_hex(dyldResult.entryPoint)
            kprint("\n")

            // Find executable (shell)
            if let (file, size) = findFile(
                in: rdStart, size: rdSize, named: "init")
            {
                kprint("Found /bin/zsh\n")
                if let result = loadMachO(
                    data: file, size: size,
                    slide: 0xFFFF_FFFF_0200_0000  // Wrapping: 0x100000000 + this = 0x02000000
                ) {
                    kprint("Loaded zsh. Entry: ")
                    kprint_hex(result.entryPoint)
                    kprint("\n")

                    if dyldResult.entryPoint != 0 {
                        // Set up the stack for dyld
                        // Stack must be mapped. We use high memory to avoid conflicts.
                        let stackSize: UInt64 = 0x4000
                        let stackTopVirt: UInt64 = 0x7000_0000
                        let stackStartVirt = stackTopVirt - stackSize

                        kprint("Mapping user stack at ")
                        kprint_hex(stackStartVirt)
                        kprint("...\n")

                        for i in 0..<(stackSize / 4096) {
                            if let frame = PMM.allocateFrame() {
                                VMM.map(
                                    virt: stackStartVirt + (UInt64(i) * 4096), phys: frame, flags: 7
                                )
                            }
                        }

                        let zshSlide: UInt64 = 0xFFFF_FFFF_0200_0000
                        let userStack = setupDyldStack(
                            execPath: "init",
                            textBase: result.textBase &+ zshSlide,  // slid mach_header addr
                            entryPoint: result.entryPoint,
                            stackTop: stackTopVirt
                        )

                        // Remap user regions with USER permission (7 = Present | RW | User)
                        remapUserRange(start: 0x0200_0000, size: 0x0100_0000)  // 16MB
                        remapUserRange(start: 0x1000_0000, size: 0x0100_0000)  // 16MB
                        remapUserRange(start: 0x1EE0_0000, size: 0x0020_0000)  // 2MB

                        // Map fake CommPage (address used by macOS for system info)
                        kprint("Allocating CommPage frame...\n")
                        if let cpFrame = PMM.allocateFrame() {
                            kprint("Mapping CommPage...\n")
                            VMM.map(virt: 0x7FFF_FFE0_0000, phys: cpFrame, flags: 7)
                            kprint("CommPage mapped.\n")
                        }

                        kprint("Jumping to dyld...\n")
                        jump_to_user(dyldResult.entryPoint, userStack)
                    }
                } else {
                    kprint("dyld not found in ramdisk, jumping to binary entry\n")
                }
            }

            // No dylinker or dyld not found - jump directly to binary
            let userStackAddr: UInt64 = 0x900000
            kprint("Jumping to Userspace...\n")
            // jump_to_user(result.entryPoint, userStackAddr)
        } else {
            kprint("Error: Failed to load Mach-O\n")
        }
    } else {
        // Flat binary (like our init.S)
        kprint("Loading flat binary...\n")
        // jump_to_user(0x800000, 0x900000)
    }

    while true { asm_hlt() }
}

// MARK: - dyld Stack Setup

/// Set up the user stack the way dyld expects it.
/// dyld4::KernelArgs layout:
///   [SP+0]  = mainExecutable mach_header pointer
///   [SP+8]  = argc
///   [SP+16] = argv[0]
///   [SP+16+argc*8] = NULL (argv terminator)
///   then envp[], NULL, apple[], NULL
func setupDyldStack(execPath: StaticString, textBase: UInt64, entryPoint: UInt64, stackTop: UInt64)
    -> UInt64
{
    let stackPage = UnsafeMutablePointer<UInt8>(bitPattern: UInt(stackTop - 0x4000))!
    memset(stackPage, 0, 0x4000)

    // Build strings area at the top of the stack page
    var stringPtr = stackTop - 0x100

    // Write executable path string
    let execPathAddr = stringPtr
    let dest = UnsafeMutablePointer<UInt8>(bitPattern: UInt(stringPtr))!
    let src = execPath.utf8Start
    for i in 0..<execPath.utf8CodeUnitCount { dest[i] = src[i] }
    dest[execPath.utf8CodeUnitCount] = 0
    stringPtr -= UInt64(execPath.utf8CodeUnitCount + 1)

    // dyld4::KernelArgs layout on the stack:
    //   [0]  mainExecutable (mach_header*) - pointer to main binary's mach_header
    //   [1]  argc
    //   [2]  argv[0]
    //   [3]  NULL  (argv terminator)
    //   [4]  NULL  (envp terminator)
    //   [5]  apple[0]
    //   [6]  NULL  (apple terminator)

    var sp = stackTop - 0x200
    sp &= ~0xF  // 16-byte align

    let spBase = UnsafeMutablePointer<UInt64>(bitPattern: UInt(sp - 7 * 8))!

    spBase[0] = textBase  // mainExecutable mach_header pointer
    spBase[1] = 1  // argc = 1
    spBase[2] = execPathAddr  // argv[0]
    spBase[3] = 0  // argv terminator
    spBase[4] = 0  // envp terminator
    spBase[5] = execPathAddr  // apple[0] (executable_path)
    spBase[6] = 0  // apple terminator

    kprint("User Stack (KernelArgs):\n")
    kprint("  SP: ")
    kprint_hex(UInt64(UInt(bitPattern: spBase)))
    kprint("\n  mainExec: ")
    kprint_hex(textBase)
    kprint("\n  argc: 1\n")

    return UInt64(UInt(bitPattern: spBase))
}

// MARK: - Utility Functions

func kprint_hex(_ v: UInt64) {
    let hex: StaticString = "0123456789ABCDEF"
    let h = hex.utf8Start
    for i in 0..<16 {
        let shift = (15 - i) * 4
        let digit = Int((v >> shift) & 0xF)
        serial_putc(h[digit])
    }
}

@_silgen_name("kprint")
func kprint(_ s: StaticString) {
    let p = s.utf8Start
    for i in 0..<s.utf8CodeUnitCount { serial_putc(p[i]) }
}

func remapUserRange(start: UInt64, size: UInt64) {
    let pages = (size + 4095) / 4096
    for i in 0..<pages {
        let addr = start + UInt64(i * 4096)
        VMM.map(virt: addr, phys: PhysAddr(addr), flags: 7)
    }
}
