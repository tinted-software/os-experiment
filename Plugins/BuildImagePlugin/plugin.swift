import Foundation
import PackagePlugin

@main
struct BuildImagePlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let triple = "x86_64-unknown-none-elf"
        let toolchainPath =
            "/Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2026-02-06-a.xctoolchain/usr/bin"

        func run(_ executable: String, _ args: [String], cwd: URL? = nil) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let cwd = cwd {
                process.currentDirectoryURL = cwd
            }
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(domain: "BuildImagePlugin", code: Int(process.terminationStatus))
            }
        }

        // We assume the user has already run `swift build --triple x86_64-unknown-none-elf`
        // print("Building targets...")
        // try run("\(toolchainPath)/swift", ["build", "--triple", triple])

        let buildDir = context.package.directoryURL.appendingPathComponent(".build")
            .appendingPathComponent(triple).appendingPathComponent("debug")

        let kernelElf64 = buildDir.appendingPathComponent("kernel.elf64")
        let kernelElf32 = buildDir.appendingPathComponent("kernel")
        let initElf = buildDir.appendingPathComponent("init.elf")
        let initBin = buildDir.appendingPathComponent("init.bin")
        let ramdiskCpio = buildDir.appendingPathComponent("ramdisk.cpio")

        print("Linking InitialProcess...")
        try run(
            "\(toolchainPath)/ld.lld",
            [
                "-Ttext", "0x800000",
                "-o", initElf.path,
                buildDir.appendingPathComponent("InitialProcess.build/init.S.o").path,
                "--nostdlib", "-static",
            ])

        print("Creating init.bin...")
        try run("\(toolchainPath)/llvm-objcopy", ["-O", "binary", initElf.path, initBin.path])

        print("Creating ramdisk...")
        try run(
            "/bin/sh",
            [
                "-c",
                "rm -rf ramdisk_root && mkdir -p ramdisk_root && cp \(initBin.path) ramdisk_root/init && cd ramdisk_root && find init | cpio -o -H newc > \(ramdiskCpio.path)",
            ])

        print("Linking Kernel...")
        try run(
            "\(toolchainPath)/ld.lld",
            [
                "-T",
                context.package.directoryURL.appendingPathComponent("Sources/Boot/linker.ld").path,
                "-o", kernelElf64.path,
                buildDir.appendingPathComponent("Kernel.build/CPIO.swift.o").path,
                buildDir.appendingPathComponent("Kernel.build/KernelMain.swift.o").path,
                buildDir.appendingPathComponent("Kernel.build/Multiboot.swift.o").path,
                buildDir.appendingPathComponent("Kernel.build/virtio_gpu.swift.o").path,
                buildDir.appendingPathComponent("Boot.build/boot.S.o").path,
                buildDir.appendingPathComponent("CSupport.build/runtime.c.o").path,
                "--nostdlib", "-static",
            ])

        print("Creating kernel (elf32)...")
        try run(
            "\(toolchainPath)/llvm-objcopy",
            ["-I", "elf64-x86-64", "-O", "elf32-i386", kernelElf64.path, kernelElf32.path])

        print("\nBuild Completed!")
        print("Kernel: \(kernelElf32.path)")
        print("Ramdisk: \(ramdiskCpio.path)")
        print("\nTo run:")
        print(
            "qemu-system-x86_64 -kernel \(kernelElf32.path) -initrd \(ramdiskCpio.path) -serial stdio -display none"
        )
    }
}
