// Kernel bump allocator for kernel_alloc used by C runtime and drivers

pub var nextKernelAddr: usize = 0x0010_0000 + 4096 * 16; // 1MB + 64KB stack

pub export fn kernel_alloc(size: usize, alignment: usize) callconv(.c) ?*u8 {
    var a = alignment;
    if (a == 0) a = 1;
    const mask: usize = @as(usize, a - 1);
    const aligned = (nextKernelAddr + mask) & ~mask;
    nextKernelAddr = aligned + size;
    return @ptrFromInt(aligned);
}
