pub const Multiboot2Header = extern struct {
    total_size: u32,
    reserved: u32,
};

pub const Multiboot2Tag = extern struct {
    type: u32,
    size: u32,
};

pub const Multiboot2TagModule = extern struct {
    type: u32,
    size: u32,
    mod_start: u32,
    mod_end: u32,
    string: u8, // Start of null-terminated string
};

// ... MB2 tags ...

// Multiboot 1
pub const MultibootInfo = extern struct {
    flags: u32,
    mem_lower: u32,
    mem_upper: u32,
    boot_device: u32,
    cmdline: u32,
    mods_count: u32,
    mods_addr: u32,
    syms: [4]u32,
    mmap_length: u32,
    mmap_addr: u32,
    drives_length: u32,
    drives_addr: u32,
    config_table: u32,
    boot_loader_name: u32,
    apm_table: u32,
    vbe_control_info: u32,
    vbe_mode_info: u32,
    vbe_mode: u16,
    vbe_interface_seg: u16,
    vbe_interface_off: u16,
    vbe_interface_len: u16,
};

pub const MultibootModule = extern struct {
    mod_start: u32,
    mod_end: u32,
    string: u32,
    reserved: u32,
};
