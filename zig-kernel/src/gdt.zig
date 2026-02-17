const main = @import("main.zig");

pub const TssEntry = extern struct {
    res0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    res1: u64 = 0,
    ist: [7]u64 = [_]u64{0} ** 7,
    res2: u64 = 0,
    res3: u16 = 0,
    iopb: u16 = 0,
};

var tss: TssEntry align(16) = .{};

var gdt = [_]u64{
    0, // Null
    0x00af9b000000ffff, // Kernel Code 64
    0x00cf93000000ffff, // Kernel Data 64
    0x00affb000000ffff, // User Code 64
    0x00cff3000000ffff, // User Data 64
    0x00affa000000ffff, // Kernel Code 32 (optional but kept for compatibility with runtime.c)
    0, // TSS Low
    0, // TSS High
};

extern fn load_gdt(ptr: *const anyopaque) void;

pub fn init(kstack: u64) void {
    main.kprint("GDT init with stack: 0x");
    main.kprintHex(kstack);
    main.kprint("\n");

    tss.rsp0 = kstack;
    tss.iopb = @sizeOf(TssEntry);

    const base = @intFromPtr(&tss);
    const limit: u32 = @sizeOf(TssEntry) - 1;

    gdt[6] = (limit & 0xffff) |
        ((base & 0xffff) << 16) |
        ((base & 0xff0000) << 16) |
        (@as(u64, 0x89) << 40) |
        (((base & 0xff000000) >> 24) << 56);
    gdt[7] = (base >> 32);

    const Gdtr = packed struct(u80) {
        limit: u16,
        base: u64,
    };

    const gdtr = Gdtr{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };

    load_gdt(&gdtr);
    main.kprint("GDT loaded\n");

    asm volatile ("ltr %%ax"
        :
        : [ax] "{ax}" (@as(u16, 0x30)),
    );
    main.kprint("TSS loaded\n");
}
