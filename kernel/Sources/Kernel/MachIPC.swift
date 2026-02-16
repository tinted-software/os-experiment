import CSupport

// MARK: - Mach Port Types

typealias MachPortName = UInt32

let MACH_PORT_NULL: MachPortName = 0
let MACH_PORT_DEAD: MachPortName = ~0

// Mach port rights
let MACH_PORT_RIGHT_SEND: UInt32 = 0
let MACH_PORT_RIGHT_RECEIVE: UInt32 = 1
let MACH_PORT_RIGHT_SEND_ONCE: UInt32 = 2

// Message options
let MACH_SEND_MSG: UInt32 = 0x0000_0001
let MACH_RCV_MSG: UInt32 = 0x0000_0002
let MACH_RCV_LARGE: UInt32 = 0x0000_0004
let MACH_SEND_TIMEOUT: UInt32 = 0x0000_0010
let MACH_RCV_TIMEOUT: UInt32 = 0x0000_0100

// Return codes
let KERN_SUCCESS: UInt32 = 0
let KERN_INVALID_ARGUMENT: UInt32 = 4
let KERN_NO_SPACE: UInt32 = 3
let KERN_INVALID_NAME: UInt32 = 15

let MACH_MSG_SUCCESS: UInt32 = 0
let MACH_RCV_TIMED_OUT: UInt32 = 0x1000_4003

// Special ports
let TASK_BOOTSTRAP_PORT: UInt32 = 4

// MARK: - Mach Message Header (matches XNU mach_msg_header_t)

struct MachMsgHeader {
    var msgh_bits: UInt32
    var msgh_size: UInt32
    var msgh_remote_port: MachPortName
    var msgh_local_port: MachPortName
    var msgh_voucher_port: MachPortName
    var msgh_id: Int32
}

// MARK: - Port Table Entry

struct MachPort {
    var name: MachPortName
    var rightType: UInt32
    var msgQueue: UnsafeMutablePointer<MachMsgBuffer>?
    var msgCount: Int
}

struct MachMsgBuffer {
    var data: UnsafeMutablePointer<UInt8>
    var size: Int
    var next: UnsafeMutablePointer<MachMsgBuffer>?
}

// MARK: - Port Space

let MAX_PORTS = 256

// Global port table (single-process for now)
nonisolated(unsafe) var portTable:
    (
        MachPort, MachPort, MachPort, MachPort, MachPort, MachPort, MachPort, MachPort,
        MachPort, MachPort, MachPort, MachPort, MachPort, MachPort, MachPort, MachPort,
        MachPort, MachPort, MachPort, MachPort, MachPort, MachPort, MachPort, MachPort,
        MachPort, MachPort, MachPort, MachPort, MachPort, MachPort, MachPort, MachPort
    ) = (
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0),
        MachPort(name: 0, rightType: 0, msgQueue: nil, msgCount: 0)
    )

nonisolated(unsafe) var nextPortName: MachPortName = 0x103  // Start after well-known ports

// MARK: - Port Operations

func machPortAllocate(rightType: UInt32) -> MachPortName {
    let name = nextPortName
    nextPortName += 1
    return name
}

func machTaskSelf() -> MachPortName {
    return 0x103  // Fixed task port
}

func machReplyPort() -> MachPortName {
    return machPortAllocate(rightType: MACH_PORT_RIGHT_RECEIVE)
}

func machHostSelf() -> MachPortName {
    return 0x104  // Fixed host port
}

// MARK: - Mach RPC Handlers

/// Handle mach_msg trap - the core IPC primitive
func handleMachMsg(
    msgAddr: UInt64, option: UInt32, sendSize: UInt32,
    rcvSize: UInt32, rcvName: MachPortName, timeout: UInt32
) -> UInt32 {
    // If sending, we need to process the message
    if (option & MACH_SEND_MSG) != 0 {
        let hdr = UnsafePointer<MachMsgHeader>(bitPattern: UInt(msgAddr))!.pointee

        kprint("  mach_msg SEND id=")
        kprint_hex(UInt64(bitPattern: Int64(hdr.msgh_id)))
        kprint(" remote=")
        kprint_hex(UInt64(hdr.msgh_remote_port))
        kprint("\n")
    }

    // If receiving with timeout, return timed out (stub: nothing to receive)
    if (option & MACH_RCV_MSG) != 0 {
        if (option & MACH_RCV_TIMEOUT) != 0 {
            return MACH_RCV_TIMED_OUT
        }
        // For pure receive without timeout, also return timed out to not block
        return MACH_RCV_TIMED_OUT
    }

    return MACH_MSG_SUCCESS
}

/// Handle host_info and similar Mach host RPCs
func handleHostRPC(msgId: Int32, replyAddr: UInt64) -> UInt32 {
    kprint("  host RPC id=")
    kprint_hex(UInt64(bitPattern: Int64(msgId)))
    kprint("\n")
    return KERN_SUCCESS
}
