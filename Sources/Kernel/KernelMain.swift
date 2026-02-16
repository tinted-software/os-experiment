import CSupport

@_cdecl("kmain")
public func kmain(magic: UInt32, infoAddr: UInt32) {
    kprint("SwiftOS Kernel Starting...\n")

    // Initialize Hardware
    // initVirtioGpu()

    let info = UnsafePointer<MultibootInfo>(bitPattern: UInt(infoAddr))!.pointee
    if (info.flags & (1 << 3)) != 0 && info.mods_count > 0 {
        let mod = UnsafePointer<MultibootModule>(bitPattern: UInt(info.mods_addr))!.pointee
        let rdStart = UnsafeRawPointer(bitPattern: UInt(mod.mod_start))!
        let rdSize = Int(mod.mod_end - mod.mod_start)

        if let file = findFile(in: rdStart, size: rdSize, named: "init") {
            let dest = UnsafeMutablePointer<UInt8>(bitPattern: 0x800000)!
            let src = file.data.assumingMemoryBound(to: UInt8.self)
            memcpy(dest, src, file.size)

            setup_gdt_tss(get_stack_top())
            setup_syscall_msrs()

            kprint("Jumping to Userspace...\n")
            jump_to_user(0x800000, 0x900000)
        } else {
            kprint("Error: 'init' not found in ramdisk\n")
        }
    } else {
        kprint("Error: No ramdisk found\n")
    }

    while true { asm_hlt() }
}

func kprint_hex(_ v: UInt64) {
    let hex: StaticString = "0123456789ABCDEF"
    let h = hex.utf8Start
    for i in 0..<16 {
        let shift = (15 - i) * 4
        let digit = Int((v >> shift) & 0xF)
        serial_putc(h[digit])
    }
}

@_cdecl("handle_syscall")
func handle_syscall(num: UInt64, arg1: UInt64, arg2: UInt64, arg3: UInt64) -> UInt64 {
    let xnuNum = num & 0xFFFFFF
    if xnuNum == 4 {
        let ptr = UnsafeRawPointer(bitPattern: UInt(arg2))!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(arg3) { serial_putc(ptr[i]) }
        return arg3
    } else if xnuNum == 1 {
        kprint("Exit\n")
        while true { asm_hlt() }
    }
    return 0
}

@_silgen_name("kprint")
func kprint(_ s: StaticString) {
    let p = s.utf8Start
    for i in 0..<s.utf8CodeUnitCount { serial_putc(p[i]) }
}
