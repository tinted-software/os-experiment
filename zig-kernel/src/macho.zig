pub const MH_MAGIC_64: u32 = 0xFEEDFACF;
pub const MH_CIGAM_64: u32 = 0xCFFAEDFE;

pub const FAT_MAGIC: u32 = 0xCAFEBABE;
pub const FAT_CIGAM: u32 = 0xBEBAFECA;

pub const CPU_TYPE_X86_64: u32 = 0x01000007;

pub const MH_EXECUTE: u32 = 2;
pub const MH_DYLINKER: u32 = 7;

pub const LC_SEGMENT_64: u32 = 0x19;
pub const LC_MAIN: u32 = 0x80000028 | 0; // Constants sometimes have high bit set
pub const LC_LOAD_DYLINKER: u32 = 0x0E;
pub const LC_UNIXTHREAD: u32 = 0x05;

pub const FatHeader = extern struct {
    magic: u32,
    nfat_arch: u32,
};

pub const FatArch = extern struct {
    cputype: u32,
    cpusubtype: u32,
    offset: u32,
    size: u32,
    align_val: u32,
};

pub const MachHeader64 = extern struct {
    magic: u32,
    cputype: u32,
    cpusubtype: u32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
};

pub const LoadCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
};

pub const SegmentCommand64 = extern struct {
    cmd: u32,
    cmdsize: u32,
    segname: [16]u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: u32,
    initprot: u32,
    nsects: u32,
    flags: u32,
};

pub const EntryPointCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    entryoff: u64,
    stacksize: u64,
};

pub const ThreadCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    flavor: u32,
    count: u32,
    // followed by thread state
};

pub const DylinkerCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    name_offset: u32,
};
