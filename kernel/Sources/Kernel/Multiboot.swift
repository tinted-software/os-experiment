struct MultibootInfo {
    var flags: UInt32
    var mem_lower: UInt32
    var mem_upper: UInt32
    var boot_device: UInt32
    var cmdline: UInt32
    var mods_count: UInt32
    var mods_addr: UInt32
}

struct MultibootModule {
    var mod_start: UInt32
    var mod_end: UInt32
    var string: UInt32
    var reserved: UInt32
}
