const main = @import("main.zig");

pub const IdtEntry = extern struct {
    offset_lo: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_hi: u32,
    reserved: u32,
};

var idt: [256]IdtEntry align(16) = undefined;

pub fn setGate(num: u8, handler: u64, ist: u8, type_attr: u8) void {
    idt[num] = .{
        .offset_lo = @truncate(handler),
        .selector = 0x08, // Kernel code
        .ist = ist,
        .type_attr = type_attr,
        .offset_mid = @truncate(handler >> 16),
        .offset_hi = @truncate(handler >> 32),
        .reserved = 0,
    };
}

extern fn load_idt(ptr: *const anyopaque) void;

pub fn init() void {
    for (0..256) |i| {
        setGate(@intCast(i), @intFromPtr(&irq_stub_generic), 0, 0x8E);
    }

    // Set up specific exception stubs (0-20)
    setGate(0, @intFromPtr(&isr_stub_0), 0, 0x8E);
    setGate(1, @intFromPtr(&isr_stub_1), 0, 0x8E);
    setGate(2, @intFromPtr(&isr_stub_2), 0, 0x8E);
    setGate(3, @intFromPtr(&isr_stub_3), 0, 0x8E);
    setGate(4, @intFromPtr(&isr_stub_4), 0, 0x8E);
    setGate(5, @intFromPtr(&isr_stub_5), 0, 0x8E);
    setGate(6, @intFromPtr(&isr_stub_6), 0, 0x8E);
    setGate(7, @intFromPtr(&isr_stub_7), 0, 0x8E);
    setGate(8, @intFromPtr(&isr_stub_8), 1, 0x8E); // Use IST 1
    setGate(9, @intFromPtr(&isr_stub_9), 0, 0x8E);
    setGate(10, @intFromPtr(&isr_stub_10), 0, 0x8E);
    setGate(11, @intFromPtr(&isr_stub_11), 0, 0x8E);
    setGate(12, @intFromPtr(&isr_stub_12), 0, 0x8E);
    setGate(13, @intFromPtr(&isr_stub_13), 0, 0x8E);
    setGate(14, @intFromPtr(&isr_stub_14), 0, 0x8E);
    setGate(15, @intFromPtr(&isr_stub_15), 0, 0x8E);
    setGate(16, @intFromPtr(&isr_stub_16), 0, 0x8E);
    setGate(17, @intFromPtr(&isr_stub_17), 0, 0x8E);
    setGate(18, @intFromPtr(&isr_stub_18), 0, 0x8E);
    setGate(19, @intFromPtr(&isr_stub_19), 0, 0x8E);
    setGate(20, @intFromPtr(&isr_stub_20), 0, 0x8E);

    const Idtr = packed struct(u80) {
        limit: u16,
        base: u64,
    };

    const idtr = Idtr{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    main.kprint("IDT Base: 0x");
    main.kprintHex(idtr.base);
    main.kprint(" Limit: 0x");
    main.kprintHex(idtr.limit);
    main.kprint("\n");

    load_idt(&idtr);
    main.kprint("IDT loaded\n");

    // Disable PIC
    const PIC1_DATA = 0x21;
    const PIC2_DATA = 0xA1;
    outb(PIC1_DATA, 0xFF);
    outb(PIC2_DATA, 0xFF);
}

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

extern fn isr_stub_0() void;
extern fn isr_stub_1() void;
extern fn isr_stub_2() void;
extern fn isr_stub_3() void;
extern fn isr_stub_4() void;
extern fn isr_stub_5() void;
extern fn isr_stub_6() void;
extern fn isr_stub_7() void;
extern fn isr_stub_8() void;
extern fn isr_stub_9() void;
extern fn isr_stub_10() void;
extern fn isr_stub_11() void;
extern fn isr_stub_12() void;
extern fn isr_stub_13() void;
extern fn isr_stub_14() void;
extern fn isr_stub_15() void;
extern fn isr_stub_16() void;
extern fn isr_stub_17() void;
extern fn isr_stub_18() void;
extern fn isr_stub_19() void;
extern fn isr_stub_20() void;
extern fn irq_stub_generic() void;
