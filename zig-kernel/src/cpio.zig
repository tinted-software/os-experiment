const std = @import("std");

pub const CpioHeader = extern struct {
    magic: [6]u8,
    ino: [8]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    nlink: [8]u8,
    mtime: [8]u8,
    filesize: [8]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    rdevmajor: [8]u8,
    rdevminor: [8]u8,
    namesize: [8]u8,
    check: [8]u8,
};

fn parseHex(s: []const u8) u32 {
    var result: u32 = 0;
    for (s) |c| {
        const val: u32 = switch (c) {
            '0'...'9' => c - '0',
            'A'...'F' => c - 'A' + 10,
            'a'...'f' => c - 'a' + 10,
            else => 0,
        };
        result = (result << 4) | val;
    }
    return result;
}

pub fn findFile(ramdisk: []const u8, name: []const u8) ?[]const u8 {
    var offset: usize = 0;
    while (offset + @sizeOf(CpioHeader) <= ramdisk.len) {
        const header: *const CpioHeader = @ptrCast(ramdisk[offset..].ptr);

        if (!std.mem.eql(u8, &header.magic, "070701")) {
            break;
        }

        const namesize = parseHex(&header.namesize);
        const filesize = parseHex(&header.filesize);

        const name_offset = offset + @sizeOf(CpioHeader);
        const name_in_cpio = ramdisk[name_offset .. name_offset + namesize - 1]; // -1 for null terminator

        const header_and_name_size = @sizeOf(CpioHeader) + namesize;
        const padded_header_size = (header_and_name_size + 3) & ~@as(usize, 3);

        const data_offset = offset + padded_header_size;
        const data = ramdisk[data_offset .. data_offset + filesize];

        if (std.mem.eql(u8, name_in_cpio, name)) {
            return data;
        }

        if (std.mem.eql(u8, name_in_cpio, "TRAILER!!!")) {
            break;
        }

        offset = (data_offset + filesize + 3) & ~@as(usize, 3);
    }
    return null;
}
