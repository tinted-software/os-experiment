// Simple Physical Memory Manager (bump allocator)
// Ported from kernel/Sources/Kernel/MM/PMM.swift

extern fn memset(dest: [*]u8, c: u8, n: usize) [*]u8;

pub var nextFree: usize = 0x0800_0000; // start of free physical memory
const ramEnd: usize = 0x2000_0000; // 512MB

pub fn allocateFrame() ?usize {
    if (nextFree >= ramEnd) return null;
    const frame = nextFree;
    nextFree += 4096;
    const ptr: [*]u8 = @ptrFromInt(frame);
    _ = memset(ptr, 0, 4096);
    return frame;
}

pub fn allocateFrames(count: usize) ?usize {
    const size = count * 4096;
    if (nextFree + size >= ramEnd) return null;
    const frame = nextFree;
    nextFree += size;
    const ptr: [*]u8 = @ptrFromInt(frame);
    _ = memset(ptr, 0, size);
    return frame;
}

pub fn freeFrame(frame: usize) void {
    _ = frame;
    // No-op for now (leak)
}
