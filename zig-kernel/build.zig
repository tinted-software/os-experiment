const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .ofmt = .elf,
    });

    const optimize = b.standardOptimizeOption(.{});

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .red_zone = false,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_module,
        .use_lld = true,
        .use_llvm = true,
    });
    kernel.pie = false; // Disable PIE
    kernel.link_z_notext = true; // Allow text relocations

    kernel.setLinkerScript(b.path("src/linker.ld"));
    kernel.root_module.addAssemblyFile(b.path("src/boot.S"));
    kernel.root_module.addAssemblyFile(b.path("src/isr.S"));

    kernel.link_z_max_page_size = 0x1000;
    kernel.link_z_common_page_size = 0x1000;

    kernel.entry = .{ .symbol_name = "_start" };

    b.installArtifact(kernel);
}
