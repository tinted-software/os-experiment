const std = @import("std");
const main = @import("main.zig");
const vmm = @import("vmm.zig");
const virtio_block = @import("virtio_block.zig");

pub const VNodeType = enum {
    file,
    directory,
};

pub const VNode = struct {
    type: VNodeType,
    name: []const u8,
    size: u64,
    data: ?[*]const u8, // For ramdisk files
    block_offset: u64 = 0, // For block-backed files
    is_block_backed: bool = false,
    is_random: bool = false,
    children: ?[]VNodeChild = null, // For directories

    pub fn read(self: *const VNode, offset: u64, count: usize, buffer: [*]u8) usize {
        if (self.type != .file) return 0;
        if (self.is_random) {
            main.fillRandom(buffer[0..count]);
            return count;
        }
        
        if (offset >= self.size) return 0;
        const remaining = self.size - offset;
        const to_read = if (count > remaining) @as(usize, @intCast(remaining)) else count;

        if (self.is_block_backed) {
            var bytes_done: usize = 0;
            var temp_buf: [512]u8 align(16) = undefined;

            while (bytes_done < to_read) {
                const current_offset = self.block_offset + offset + bytes_done;
                const sector = current_offset / 512;
                const sector_off = current_offset % 512;
                
                if (!virtio_block.read(sector, 1, &temp_buf)) break;
                
                const bytes_to_copy = @min(to_read - bytes_done, 512 - @as(usize, @intCast(sector_off)));
                @memcpy(buffer[bytes_done..][0..bytes_to_copy], temp_buf[sector_off..][0..bytes_to_copy]);
                bytes_done += bytes_to_copy;
            }
            return bytes_done;
        } else {
            if (self.data == null) return 0;
            @memcpy(buffer[0..to_read], self.data.?[@intCast(offset)..][0..to_read]);
            return to_read;
        }
    }

    pub fn lookup(self: *const VNode, name: []const u8) ?*const VNode {
        if (self.type != .directory or self.children == null) return null;
        for (self.children.?) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child.node;
            }
        }
        return null;
    }
};

pub const VNodeChild = struct {
    name: []const u8,
    node: *const VNode,
};

pub const FileDescription = struct {
    node: *const VNode,
    offset: u64,
};

var open_files: [128]?FileDescription = [_]?FileDescription{null} ** 128;

pub fn open(path: []const u8) !i32 {
    const node = resolve(path) orelse return -1;
    for (0..open_files.len) |i| {
        if (open_files[i] == null) {
            open_files[i] = FileDescription{
                .node = node,
                .offset = 0,
            };
            return @intCast(i + 3);
        }
    }
    return -1;
}

pub fn getFile(fd: i32) ?*FileDescription {
    if (fd < 3) return null;
    const idx = @as(usize, @intCast(fd - 3));
    if (idx >= open_files.len) return null;
    if (open_files[idx]) |*f| return f;
    return null;
}

pub fn close(fd: i32) void {
    if (fd < 3) return;
    const idx = @as(usize, @intCast(fd - 3));
    if (idx < open_files.len) {
        open_files[idx] = null;
    }
}

var root_node: VNode = undefined;
var ramdisk_nodes: [512]VNode = undefined;
var ramdisk_node_count: usize = 0;
var ramdisk_children: [1024]VNodeChild = undefined;
var ramdisk_child_count: usize = 0;

pub fn initRamdisk(data: []const u8) void {
    root_node = VNode{
        .type = .directory,
        .name = "",
        .size = 0,
        .data = null,
    };

    // Add /dev/urandom manually
    if (ramdisk_node_count < ramdisk_nodes.len) {
        const node = &ramdisk_nodes[ramdisk_node_count];
        ramdisk_node_count += 1;
        node.* = VNode{
            .type = .file,
            .name = "dev/urandom",
            .size = 0,
            .data = null,
            .is_random = true,
        };
        add_to_vfs("dev/urandom", node);
    }

    // Add /dev/random manually
    if (ramdisk_node_count < ramdisk_nodes.len) {
        const node = &ramdisk_nodes[ramdisk_node_count];
        ramdisk_node_count += 1;
        node.* = VNode{
            .type = .file,
            .name = "dev/random",
            .size = 0,
            .data = null,
            .is_random = true,
        };
        add_to_vfs("dev/random", node);
    }

    var offset: usize = 0;
    while (offset < data.len) {
        const header = @as(*const cpio_newc_header, @ptrCast(@alignCast(data[offset..].ptr)));
        if (!std.mem.eql(u8, header.c_magic[0..6], "070701")) break;

        const namesize = parseHex8(header.c_namesize);
        const filesize = parseHex8(header.c_filesize);
        const mode = parseHex8(header.c_mode);

        const name_ptr = data.ptr + offset + @sizeOf(cpio_newc_header);
        const name = name_ptr[0 .. namesize - 1];

        const header_plus_name = @sizeOf(cpio_newc_header) + namesize;
        const aligned_header_plus_name = (header_plus_name + 3) & ~@as(usize, 3);
        const file_data_ptr = data.ptr + offset + aligned_header_plus_name;

        if (std.mem.eql(u8, name, "TRAILER!!!")) break;

        if ((mode & 0o170000) == 0o100000) { // Regular file
            if (ramdisk_node_count < ramdisk_nodes.len) {
                const node = &ramdisk_nodes[ramdisk_node_count];
                ramdisk_node_count += 1;
                node.* = VNode{
                    .type = .file,
                    .name = allocateName(name),
                    .size = filesize,
                    .data = file_data_ptr,
                };
                add_to_vfs(node.name, node);
            }
        }

        const next_offset = aligned_header_plus_name + filesize;
        offset += (next_offset + 3) & ~@as(usize, 3);
    }
}

pub fn mountBlockDevice() void {
    main.kprint("Mounting Block Device...\n");
    var offset: u64 = 0;
    var header_buf: [1024]u8 align(16) = undefined;

    while (true) {
        const sector = offset / 512;
        const sector_off = offset % 512;
        
        if (!virtio_block.read(sector, 1, header_buf[0..512].ptr)) break;
        if (!virtio_block.read(sector + 1, 1, header_buf[512..1024].ptr)) break;

        const header = @as(*const cpio_newc_header, @ptrCast(@alignCast(header_buf[sector_off..].ptr)));
        if (!std.mem.eql(u8, header.c_magic[0..6], "070701")) break;

        const namesize = parseHex8(header.c_namesize);
        const filesize = parseHex8(header.c_filesize);
        const mode = parseHex8(header.c_mode);

        const name_start = sector_off + @sizeOf(cpio_newc_header);
        const name = header_buf[name_start .. name_start + namesize - 1];

        const header_plus_name = @sizeOf(cpio_newc_header) + namesize;
        const aligned_header_plus_name = (header_plus_name + 3) & ~@as(u64, 3);
        const file_data_offset = offset + aligned_header_plus_name;

        if (std.mem.eql(u8, name, "TRAILER!!!")) break;

        if ((mode & 0o170000) == 0o100000) { // Regular file
            if (ramdisk_node_count < ramdisk_nodes.len) {
                const node = &ramdisk_nodes[ramdisk_node_count];
                ramdisk_node_count += 1;
                const stored_name = allocateName(name);

                node.* = VNode{
                    .type = .file,
                    .name = stored_name,
                    .size = filesize,
                    .data = null,
                    .block_offset = file_data_offset,
                    .is_block_backed = true,
                };
                add_to_vfs(stored_name, node);
            }
        }

        const next_offset = aligned_header_plus_name + filesize;
        offset += (next_offset + 3) & ~@as(u64, 3);
    }
}

fn add_to_vfs(path: []const u8, node: *const VNode) void {
    if (ramdisk_child_count < ramdisk_children.len) {
        ramdisk_children[ramdisk_child_count] = .{ .name = path, .node = node };
        ramdisk_child_count += 1;
    }
    root_node.children = ramdisk_children[0..ramdisk_child_count];
}

pub fn resolve(path: []const u8) ?*const VNode {
    var p = path;
    while (p.len > 0 and (p[0] == '/' or p[0] == '.')) {
        if (p[0] == '/') {
            p = p[1..];
        } else if (p.len > 1 and p[0] == '.' and p[1] == '/') {
            p = p[2..];
        } else {
            break;
        }
    }
    
    // Try absolute match first
    for (root_node.children.?) |child| {
        var child_name = child.name;
        while (child_name.len > 0 and (child_name[0] == '/' or child_name[0] == '.')) {
            if (child_name[0] == '/') {
                child_name = child_name[1..];
            } else if (child_name.len > 1 and child_name[0] == '.' and child_name[1] == '/') {
                child_name = child_name[2..];
            } else {
                break;
            }
        }
        if (std.mem.eql(u8, child_name, p)) return child.node;
    }
    return null;
}

var name_pool: [32768]u8 = undefined;
var name_pool_ptr: usize = 0;

fn allocateName(name: []const u8) []const u8 {
    if (name_pool_ptr + name.len > name_pool.len) return name;
    const start = name_pool_ptr;
    @memcpy(name_pool[start .. start + name.len], name);
    name_pool_ptr += name.len;
    return name_pool[start .. start + name.len];
}

const cpio_newc_header = extern struct {
    c_magic: [6]u8,
    c_ino: [8]u8,
    c_mode: [8]u8,
    c_uid: [8]u8,
    c_gid: [8]u8,
    c_nlink: [8]u8,
    c_mtime: [8]u8,
    c_filesize: [8]u8,
    c_devmajor: [8]u8,
    c_devminor: [8]u8,
    c_rdevmajor: [8]u8,
    c_rdevminor: [8]u8,
    c_namesize: [8]u8,
    c_check: [8]u8,
};

fn parseHex8(s: [8]u8) u32 {
    var res: u32 = 0;
    for (s) |c| {
        res <<= 4;
        if (c >= '0' and c <= '9') {
            res += (c - '0');
        } else if (c >= 'a' and c <= 'f') {
            res += (c - 'a' + 10);
        } else if (c >= 'A' and c <= 'F') {
            res += (c - 'A' + 10);
        }
    }
    return res;
}
