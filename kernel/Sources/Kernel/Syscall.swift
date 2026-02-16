import CSupport

// MARK: - XNU Syscall Classes
// XNU syscalls are encoded as: class << 24 | number
// Class 0: Mach traps (negative numbers in traditional BSD, but encoded as 0x0000xxxx)
// Class 1: Unix/BSD syscalls (0x01000000 | num)
// Class 2: Mach (0x02000000 | num)
// Class 3: Diagnostics

let SYSCALL_CLASS_MACH: UInt64 = 0x0100_0000
let SYSCALL_CLASS_UNIX: UInt64 = 0x0200_0000

// MARK: - Mach Trap Numbers

let MACH_TRAP_REPLY_PORT: UInt64 = 26
let MACH_TRAP_THREAD_SELF: UInt64 = 27
let MACH_TRAP_TASK_SELF: UInt64 = 28
let MACH_TRAP_HOST_SELF: UInt64 = 29
let MACH_TRAP_MSG: UInt64 = 31
let MACH_TRAP_MSG_OVERWRITE: UInt64 = 32
let MACH_TRAP_SEMAPHORE_SIGNAL: UInt64 = 33
let MACH_TRAP_SEMAPHORE_WAIT: UInt64 = 36
let MACH_TRAP_THREAD_GET_SPECIAL_PORT: UInt64 = 0
let MACH_TRAP_PORT_ALLOCATE: UInt64 = 3616  // _kernelrpc_mach_port_allocate_trap
let MACH_TRAP_PORT_DEALLOCATE: UInt64 = 3618
let MACH_TRAP_PORT_INSERT_RIGHT: UInt64 = 3619
let MACH_TRAP_PORT_CONSTRUCT: UInt64 = 3624
let MACH_TRAP_VM_ALLOCATE: UInt64 = 3610  // _kernelrpc_mach_vm_allocate_trap
let MACH_TRAP_VM_DEALLOCATE: UInt64 = 3612
let MACH_TRAP_VM_PROTECT: UInt64 = 3614
let MACH_TRAP_VM_MAP: UInt64 = 3613

// MARK: - BSD Syscall Numbers

let SYS_EXIT: UInt64 = 1
let SYS_FORK: UInt64 = 2
let SYS_READ: UInt64 = 3
let SYS_WRITE: UInt64 = 4
let SYS_OPEN: UInt64 = 5
let SYS_CLOSE: UInt64 = 6
let SYS_MMAP: UInt64 = 197
let SYS_MUNMAP: UInt64 = 73
let SYS_MPROTECT: UInt64 = 74
let SYS_SIGPROCMASK: UInt64 = 48
let SYS_IOCTL: UInt64 = 54
let SYS_FCNTL: UInt64 = 92
let SYS_GETPID: UInt64 = 20
let SYS_GETUID: UInt64 = 24
let SYS_GETEUID: UInt64 = 25
let SYS_GETGID: UInt64 = 47
let SYS_GETEGID: UInt64 = 43
let SYS_ISSETUGID: UInt64 = 327
let SYS_CSOPS: UInt64 = 169
let SYS_CSOPS_AUDITTOKEN: UInt64 = 170
let SYS_PROC_INFO: UInt64 = 336
let SYS_SHARED_REGION_CHECK: UInt64 = 294
let SYS_SYSCTL: UInt64 = 202
let SYS_SYSCTLBYNAME: UInt64 = 274
let SYS_STAT64: UInt64 = 338
let SYS_FSTAT64: UInt64 = 339
let SYS_LSTAT64: UInt64 = 340
let SYS_GETENTROPY: UInt64 = 500
let SYS_BRK: UInt64 = 12
let SYS_THREAD_SELFID: UInt64 = 372
let SYS_ACCESS: UInt64 = 33
let SYS_DUP2: UInt64 = 90
let SYS_SIGACTION: UInt64 = 46
let SYS_PIPE: UInt64 = 42
let SYS_GETRLIMIT: UInt64 = 194
let SYS_SETRLIMIT: UInt64 = 195
let SYS_WRITEV: UInt64 = 121

// MARK: - Process State (simple single-process for now)

nonisolated(unsafe) var currentBrk: UInt64 = 0x0400_0000  // Heap start
// 128MB - safely within 512MB RAM
nonisolated(unsafe) var nextMmapAddr: UInt64 = 0x0800_0000
nonisolated(unsafe) var signalMask: UInt64 = 0

// MARK: - Main Syscall Dispatcher

/// Called from the assembly syscall_entry stub.
/// RAX = syscall number (XNU-encoded), RDI..R9 = args
@_cdecl("handle_syscall")
func handleSyscall(
    num: UInt64, arg1: UInt64, arg2: UInt64, arg3: UInt64,
    arg4: UInt64, arg5: UInt64, arg6: UInt64
) -> UInt64 {
    let syscallClass = num & 0xFF00_0000
    let syscallNum = num & 0x00FF_FFFF

    switch syscallClass {
    case SYSCALL_CLASS_UNIX:
        return handleBSDSyscall(
            num: syscallNum, a1: arg1, a2: arg2, a3: arg3, a4: arg4, a5: arg5, a6: arg6)
    case SYSCALL_CLASS_MACH:
        return handleMachTrap(
            num: syscallNum, a1: arg1, a2: arg2, a3: arg3, a4: arg4, a5: arg5, a6: arg6)
    case SYSCALL_CLASS_MDEP:
        return handleMachineDependentSyscall(
            num: syscallNum, a1: arg1, a2: arg2, a3: arg3, a4: arg4, a5: arg5, a6: arg6)

    case 0:
        // Mach traps can also be called with class 0 (negative trap numbers in XNU)
        return handleMachTrap(
            num: syscallNum, a1: arg1, a2: arg2, a3: arg3, a4: arg4, a5: arg5, a6: arg6)
    default:
        kprint("SYSCALL: Unknown class ")
        kprint_hex(num)
        kprint("\n")
        return UInt64(bitPattern: -1)
    }
}

let SYSCALL_CLASS_MDEP: UInt64 = 0x0300_0000

func handleMachineDependentSyscall(
    num: UInt64, a1: UInt64, a2: UInt64, a3: UInt64, a4: UInt64, a5: UInt64, a6: UInt64
) -> UInt64 {
    switch num {
    case 3:  // thread_set_tsd_base
        // a1 = new tsd base (GS Base)
        kprint("thread_set_tsd_base: ")
        kprint_hex(a1)
        kprint("\n")
        asm_wrmsr(0xC000_0102, a1)
        return 0
    default:
        kprint("MDEP: Unknown syscall ")
        kprint_hex(num)
        kprint("\n")
        return 0
    }
}

// MARK: - BSD Syscall Handler

func handleBSDSyscall(
    num: UInt64, a1: UInt64, a2: UInt64, a3: UInt64, a4: UInt64, a5: UInt64, a6: UInt64
) -> UInt64 {
    switch num {
    case SYS_EXIT:
        kprint("exit(")
        kprint_hex(a1)
        kprint(")\n")
        while true { asm_hlt() }

    case SYS_WRITE:
        // write(fd, buf, count)
        let buf = UnsafeRawPointer(bitPattern: UInt(a2))
        if let buf = buf {
            let ptr = buf.assumingMemoryBound(to: UInt8.self)
            for i in 0..<Int(a3) { serial_putc(ptr[i]) }
        }
        return a3

    case SYS_READ:
        // read(fd, buf, count) - stub: return 0 (EOF)
        return 0

    case SYS_OPEN:
        // open(path, flags, mode) - stub: return fd 3
        if let pathPtr = UnsafeRawPointer(bitPattern: UInt(a1)) {
            kprint("open(\"")
            let p = pathPtr.assumingMemoryBound(to: UInt8.self)
            var i = 0
            while p[i] != 0 && i < 64 {
                serial_putc(p[i])
                i += 1
            }
            kprint("\")\n")
        }
        return UInt64(bitPattern: -1)  // ENOENT

    case SYS_CLOSE:
        return 0

    case SYS_MMAP:
        // mmap(addr, len, prot, flags, fd, offset)
        // a1=addr, a2=len, a3=prot, a4=flags, a5=fd, a6=offset
        let addr = a1
        let len = a2
        let fd = Int(bitPattern: UInt(a5))
        let offset = a6

        let allocAddr: UInt64
        if addr != 0 {
            allocAddr = addr
        } else {
            allocAddr = nextMmapAddr
            nextMmapAddr = (nextMmapAddr + len + 0xFFF) & ~0xFFF
        }

        // Allocate pages
        let pageCount = (len + 0xFFF) / 4096
        for i in 0..<pageCount {
            if let frame = PMM.allocateFrame() {
                VMM.map(virt: allocAddr + (i * 4096), phys: frame, flags: 7)
            } else {
                return UInt64(bitPattern: -1)
            }
        }

        // File backing
        if let dest = UnsafeMutableRawPointer(bitPattern: UInt(allocAddr)) {
            if fd != -1 {
                if let file = VFS.shared.getFileDescription(fd: fd) {
                    _ = file.vnode.read(offset: offset, count: Int(len), buffer: dest)
                }
            }
        }
        return allocAddr

    case SYS_MUNMAP:
        return 0

    case SYS_MPROTECT:
        return 0

    case SYS_BRK:
        if a1 == 0 { return currentBrk }
        currentBrk = a1
        return 0

    case SYS_SIGPROCMASK:
        // sigprocmask(how, set, oset)
        let osetAddr = a3
        if osetAddr != 0 {
            if let oset = UnsafeMutablePointer<UInt64>(bitPattern: UInt(osetAddr)) {
                oset.pointee = signalMask
            }
        }
        if a2 != 0 {
            if let setPtr = UnsafePointer<UInt64>(bitPattern: UInt(a2)) {
                let newSet = setPtr.pointee
                switch a1 {
                case 1: signalMask |= newSet  // SIG_BLOCK
                case 2: signalMask &= ~newSet  // SIG_UNBLOCK
                case 3: signalMask = newSet  // SIG_SETMASK
                default: break
                }
            }
        }
        return 0

    case SYS_SIGACTION:
        return 0

    case SYS_GETPID:
        return 1

    case SYS_GETUID, SYS_GETEUID:
        return 0  // root

    case SYS_GETGID, SYS_GETEGID:
        return 0  // root

    case SYS_ISSETUGID:
        return 0

    case SYS_IOCTL:
        return 0

    case SYS_FCNTL:
        return 0

    case SYS_CSOPS, SYS_CSOPS_AUDITTOKEN:
        return 0

    case SYS_PROC_INFO:
        return 0

    case SYS_SHARED_REGION_CHECK:
        // shared_region_check_np(addr) - return 0 to indicate no shared region
        if a1 != 0 {
            if let p = UnsafeMutablePointer<UInt64>(bitPattern: UInt(a1)) {
                p.pointee = 0
            }
        }
        return 0

    case SYS_SYSCTL:
        return handleSysctl(a1: a1, a2: a2, a3: a3)

    case SYS_SYSCTLBYNAME:
        return 0

    case SYS_OPEN:
        let pathPtr = UnsafePointer<UInt8>(bitPattern: UInt(a1))!
        let flags = Int(a2)
        // Convert C string to Swift String (basic)
        var path = ""
        var i = 0
        while pathPtr[i] != 0 {
            path.append(Character(UnicodeScalar(pathPtr[i])))
            i += 1
        }
        if let fd = VFS.shared.open(path: path, flags: flags) {
            return UInt64(fd)
        }
        return UInt64(bitPattern: -2)  // ENOENT

    case SYS_CLOSE:
        VFS.shared.close(fd: Int(a1))
        return 0

    case SYS_READ:
        let fd = Int(a1)
        if let buf = UnsafeMutableRawPointer(bitPattern: UInt(a2)) {
            let count = Int(a3)
            if let file = VFS.shared.getFileDescription(fd: fd) {
                return UInt64(file.read(buffer: buf, count: count))
            }
        }
        // stdin fallback?
        return UInt64(bitPattern: -9)  // EBADF

    case SYS_WRITE:
        let fd = Int(a1)
        if fd == 1 || fd == 2 {
            if let buf = UnsafePointer<UInt8>(bitPattern: UInt(a2)) {
                let count = Int(a3)
                for i in 0..<count {
                    serial_putc(buf[i])
                }
                return UInt64(count)
            }
        }
        // TODO: VFS write
        return UInt64(bitPattern: -9)  // EBADF

    case SYS_FSTAT64:
        let fd = Int(a1)
        if let statPtr = UnsafeMutableRawPointer(bitPattern: UInt(a2)) {
            if let file = VFS.shared.getFileDescription(fd: fd) {
                let size = file.vnode.size
                // struct stat64 is large. We need the definition.
                // st_mode offset 0 (kind of), st_size offset 96?
                // Helper:
                // mode: S_IFREG (0x8000) or S_IFDIR (0x4000)
                var mode: UInt16 = 0
                switch file.vnode.type {
                case .file: mode = 0x8000 | 0o644
                case .directory: mode = 0x4000 | 0o755
                default: mode = 0
                }

                memset(statPtr, 0, 144)  // approximate size of stat64
                // st_mode at offset 4 (UInt16)
                statPtr.storeBytes(of: mode, toByteOffset: 4, as: UInt16.self)
                // st_size at offset 96 (Int64)
                statPtr.storeBytes(of: Int64(size), toByteOffset: 96, as: Int64.self)
                return 0
            }
        }
        return UInt64(bitPattern: -9)  // EBADF

    case SYS_STAT64, SYS_LSTAT64:
        // Stat by path.
        return UInt64(bitPattern: -2)  // ENOENT

    case SYS_GETENTROPY:
        // getentropy(buf, buflen)
        if let buf = UnsafeMutableRawPointer(bitPattern: UInt(a1)) {
            let p = buf.assumingMemoryBound(to: UInt8.self)
            for i in 0..<Int(a2) { p[i] = UInt8(truncatingIfNeeded: i &* 0x5_DEEC_E66D &+ 0xB) }
        }
        return 0

    case SYS_THREAD_SELFID:
        return 1  // Thread ID

    case SYS_ACCESS:
        return UInt64(bitPattern: -1)  // ENOENT

    case SYS_GETRLIMIT:
        // getrlimit(resource, rlp)
        if let rlp = UnsafeMutablePointer<UInt64>(bitPattern: UInt(a2)) {
            rlp[0] = 0x0080_0000  // cur (8MB)
            rlp[1] = 0x0080_0000  // max
        }
        return 0

    case SYS_SETRLIMIT:
        return 0

    case SYS_WRITEV:
        // writev(fd, iov, iovcnt)
        // struct iovec { void *iov_base; size_t iov_len; }
        if let iovPtr = UnsafePointer<UInt64>(bitPattern: UInt(a2)) {
            var total: UInt64 = 0
            for i in 0..<Int(a3) {
                let base = iovPtr[i * 2]
                let len = iovPtr[i * 2 + 1]
                if let buf = UnsafeRawPointer(bitPattern: UInt(base)) {
                    let p = buf.assumingMemoryBound(to: UInt8.self)
                    for j in 0..<Int(len) { serial_putc(p[j]) }
                }
                total += len
            }
            return total
        }
        return UInt64(bitPattern: -1)

    case SYS_PIPE:
        return UInt64(bitPattern: -1)

    case SYS_DUP2:
        return a2  // Return newfd

    default:
        kprint("BSD: Unknown syscall ")
        kprint_hex(num)
        kprint("\n")
        return 0
    }
}

// MARK: - Mach Trap Handler

func handleMachTrap(
    num: UInt64, a1: UInt64, a2: UInt64, a3: UInt64, a4: UInt64, a5: UInt64, a6: UInt64
) -> UInt64 {
    switch num {
    case MACH_TRAP_REPLY_PORT:
        return UInt64(machReplyPort())

    case MACH_TRAP_THREAD_SELF:
        return 0x203  // Fixed thread port

    case MACH_TRAP_TASK_SELF:
        return UInt64(machTaskSelf())

    case MACH_TRAP_HOST_SELF:
        return UInt64(machHostSelf())

    case MACH_TRAP_MSG, MACH_TRAP_MSG_OVERWRITE:
        // mach_msg_trap(msg, option, send_size, rcv_size, rcv_name, timeout, notify)
        return UInt64(
            handleMachMsg(
                msgAddr: a1,
                option: UInt32(a2),
                sendSize: UInt32(a3),
                rcvSize: UInt32(a4),
                rcvName: MachPortName(a5),
                timeout: UInt32(a6)
            ))

    case MACH_TRAP_PORT_ALLOCATE:
        // _kernelrpc_mach_port_allocate_trap(task, right, name_out)
        let name = machPortAllocate(rightType: UInt32(a2))
        if let nameOut = UnsafeMutablePointer<UInt32>(bitPattern: UInt(a3)) {
            nameOut.pointee = name
        }
        return 0  // KERN_SUCCESS

    case MACH_TRAP_PORT_DEALLOCATE:
        return 0

    case MACH_TRAP_PORT_INSERT_RIGHT:
        return 0

    case MACH_TRAP_PORT_CONSTRUCT:
        // _kernelrpc_mach_port_construct_trap(task, options, context, name_out)
        let name = machPortAllocate(rightType: MACH_PORT_RIGHT_RECEIVE)
        if let nameOut = UnsafeMutablePointer<UInt32>(bitPattern: UInt(a3)) {
            nameOut.pointee = name
        }
        return 0

    case MACH_TRAP_VM_ALLOCATE:
        // _kernelrpc_mach_vm_allocate_trap(task, addr_p, size, flags)
        let size = a2
        let addrPtr = UnsafeMutablePointer<UInt64>(bitPattern: UInt(a1))
        let addr = nextMmapAddr
        nextMmapAddr += (size + 0xFFF) & ~0xFFF
        if let p = addrPtr {
            p.pointee = addr
        }
        // Zero-fill
        if let dest = UnsafeMutableRawPointer(bitPattern: UInt(addr)) {
            memset(dest, 0, Int(size))
        }
        return 0

    case MACH_TRAP_VM_DEALLOCATE:
        return 0

    case MACH_TRAP_VM_PROTECT:
        return 0

    case MACH_TRAP_VM_MAP:
        return 0

    case MACH_TRAP_SEMAPHORE_SIGNAL:
        return 0

    case MACH_TRAP_SEMAPHORE_WAIT:
        return 0

    default:
        kprint("Mach: Unknown trap ")
        kprint_hex(num)
        kprint("\n")
        return 0
    }
}

// MARK: - sysctl handler

func handleSysctl(a1: UInt64, a2: UInt64, a3: UInt64) -> UInt64 {
    // sysctl(name, namelen, oldp, oldlenp, newp, newlen)
    // name is an array of int
    guard let namePtr = UnsafePointer<Int32>(bitPattern: UInt(a1)) else {
        return UInt64(bitPattern: -1)
    }
    let nameLen = Int(a2)
    if nameLen < 2 { return UInt64(bitPattern: -1) }

    let mib0 = namePtr[0]
    let mib1 = namePtr[1]

    // CTL_HW = 6, HW_NCPU = 3
    if mib0 == 6 && mib1 == 3 {
        if let oldp = UnsafeMutablePointer<Int32>(bitPattern: UInt(a3)) {
            oldp.pointee = 1  // 1 CPU
        }
        return 0
    }

    // CTL_KERN = 1, KERN_OSTYPE = 1
    if mib0 == 1 && mib1 == 1 {
        if let oldp = UnsafeMutableRawPointer(bitPattern: UInt(a3)) {
            let s: StaticString = "Darwin"
            memcpy(oldp, UnsafeRawPointer(s.utf8Start), s.utf8CodeUnitCount + 1)
        }
        return 0
    }

    return 0
}
