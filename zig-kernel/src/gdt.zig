const main = @import("main.zig");

pub const TssEntry = packed struct {
    res0: u32 = 0,
    rsp0_lo: u32 = 0,
    rsp0_hi: u32 = 0,
    rsp1_lo: u32 = 0,
    rsp1_hi: u32 = 0,
    rsp2_lo: u32 = 0,
    rsp2_hi: u32 = 0,
    res1_lo: u32 = 0,
    res1_hi: u32 = 0,
    ist1_lo: u32 = 0,
    ist1_hi: u32 = 0,
    ist2_lo: u32 = 0,
    ist2_hi: u32 = 0,
    ist3_lo: u32 = 0,
    ist3_hi: u32 = 0,
    ist4_lo: u32 = 0,
    ist4_hi: u32 = 0,
    ist5_lo: u32 = 0,
    ist5_hi: u32 = 0,
    ist6_lo: u32 = 0,
    ist6_hi: u32 = 0,
    ist7_lo: u32 = 0,
    ist7_hi: u32 = 0,
    res2_lo: u32 = 0,
    res2_hi: u32 = 0,
    res3: u16 = 0,
    iopb: u16 = 0,
};

var tss: TssEntry align(16) = .{};

var gdt = [_]u64{
    0, // Null
    0x00af9b000000ffff, // Kernel Code 64 (0x08)
    0x00cf93000000ffff, // Kernel Data 64 (0x10)
    0x00cff3000000ffff, // User Data 64 (0x18)
    0x00affb000000ffff, // User Code 64 (0x20)
    0, // TSS Low (0x28)
    0, // TSS High (0x30)
};

extern fn load_gdt(ptr: *const anyopaque) void;

pub fn init(kstack: u64) void {
    main.kprint("GDT init with stack: 0x");
    main.kprintHex(kstack);
    main.kprint("\n");

    tss.rsp0_lo = @truncate(kstack);
    tss.rsp0_hi = @truncate(kstack >> 32);
    tss.iopb = @sizeOf(TssEntry);

    tss.ist1_lo = @truncate(@intFromPtr(&df_stack_top));
    tss.ist1_hi = @truncate(@intFromPtr(&df_stack_top) >> 32);

    const base = @intFromPtr(&tss);
    const limit: u32 = @sizeOf(TssEntry) - 1;

    gdt[5] = (limit & 0xffff) |
        ((base & 0xffff) << 16) |
        (((base >> 16) & 0xff) << 32) |
        (@as(u64, 0x89) << 40) |
        (@as(u64, (limit >> 16) & 0xf) << 48) |
        (((base >> 24) & 0xff) << 56);
    gdt[6] = (base >> 32);

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
        : [ax] "{ax}" (@as(u16, 0x28)),
    );
    main.kprint("TSS loaded\n");
}

extern var df_stack_top: u8;
