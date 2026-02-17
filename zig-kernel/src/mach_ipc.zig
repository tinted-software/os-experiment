const std = @import("std");
const main = @import("main.zig");

pub const MachPortName = u32;

pub const MACH_PORT_NULL: MachPortName = 0;
pub const MACH_PORT_DEAD: MachPortName = 0xFFFFFFFF;

pub const MACH_PORT_RIGHT_SEND: u32 = 0;
pub const MACH_PORT_RIGHT_RECEIVE: u32 = 1;
pub const MACH_PORT_RIGHT_SEND_ONCE: u32 = 2;

pub const MACH_SEND_MSG: u32 = 0x00000001;
pub const MACH_RCV_MSG: u32 = 0x00000002;
pub const MACH_RCV_LARGE: u32 = 0x00000004;
pub const MACH_SEND_TIMEOUT: u32 = 0x00000010;
pub const MACH_RCV_TIMEOUT: u32 = 0x00000100;

pub const KERN_SUCCESS: u32 = 0;
pub const KERN_INVALID_ARGUMENT: u32 = 4;
pub const KERN_NO_SPACE: u32 = 3;
pub const KERN_INVALID_NAME: u32 = 15;

pub const MACH_MSG_SUCCESS: u32 = 0;
pub const MACH_RCV_TIMED_OUT: u32 = 0x10004003;

pub const MachMsgHeader = extern struct {
    msgh_bits: u32,
    msgh_size: u32,
    msgh_remote_port: MachPortName,
    msgh_local_port: MachPortName,
    msgh_voucher_port: MachPortName,
    msgh_id: i32,
};

pub const MachPort = struct {
    name: MachPortName,
    right_type: u32,
    // msg_queue: ?*MachMsgBuffer = null,
    // msg_count: usize = 0,
};

var port_table: [256]?MachPort = [_]?MachPort{null} ** 256;
var next_port_name: MachPortName = 0x10000000;

pub fn machPortAllocate(right_type: u32) MachPortName {
    _ = right_type;
    const name = next_port_name;
    next_port_name += 1;
    return name;
}

pub fn machTaskSelf() MachPortName {
    return 0x10000002;
}

pub fn machReplyPort() MachPortName {
    return machPortAllocate(MACH_PORT_RIGHT_RECEIVE);
}

pub fn machHostSelf() MachPortName {
    return 0x10000003;
}

pub fn handleMachMsg(
    msg_addr: u64,
    option: u32,
    send_size: u32,
    rcv_size: u32,
    rcv_name: MachPortName,
    timeout: u32,
) u32 {
    _ = send_size;
    _ = rcv_size;
    _ = rcv_name;
    _ = timeout;

    if ((option & MACH_SEND_MSG) != 0) {
        const hdr: *const MachMsgHeader = @ptrFromInt(@as(usize, @intCast(msg_addr)));
        main.kprint("  mach_msg SEND id=");
        main.kprintHex(@as(u64, @bitCast(@as(i64, hdr.msgh_id))));
        main.kprint(" remote=");
        main.kprintHex(hdr.msgh_remote_port);
        main.kprint("\n");
    }

    if ((option & MACH_RCV_MSG) != 0) {
        // Return timed out to avoid blocking if nothing is there
        return MACH_RCV_TIMED_OUT;
    }

    return MACH_MSG_SUCCESS;
}
