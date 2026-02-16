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

        let buildDir = context.package.directoryURL.appendingPathComponent(".build")
            .appendingPathComponent(triple).appendingPathComponent("debug")

        let kernelElf64 = buildDir.appendingPathComponent("kernel.elf64")
        let kernelElf32 = buildDir.appendingPathComponent("kernel")
        let initElf = buildDir.appendingPathComponent("init.elf")
        let initBin = buildDir.appendingPathComponent("init.bin")
        let ramdiskCpio = buildDir.appendingPathComponent("ramdisk.cpio")
        let diskImg = buildDir.appendingPathComponent("disk.img")

        // Check if we should use a Mach-O binary instead of the flat init
        let useMachO = arguments.contains("--macho")
        let machoBinary = arguments.first(where: { !$0.hasPrefix("-") && $0 != "build-image" })

        let sharedCachePath = arguments.first(where: {
            let idx = arguments.firstIndex(of: $0) ?? -1
            return idx > 0 && arguments[idx - 1] == "--shared-cache"
        })

        print("Linking InitialProcess...")
        // ... (rest of the link steps)
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
        let ramdiskRoot = buildDir.appendingPathComponent("ramdisk_root")

        // Build ramdisk contents
        var cpioCmd = "rm -rf \(ramdiskRoot.path) && mkdir -p \(ramdiskRoot.path)"

        if useMachO, let binary = machoBinary {
            // Use a Mach-O binary as "init"
            print("  Including Mach-O binary: \(binary)")
            cpioCmd += " && cp \(binary) \(ramdiskRoot.path)/init"

            // Also include dyld if it exists
            let dyldPath = "/usr/lib/dyld"
            if FileManager.default.fileExists(atPath: dyldPath) {
                print("  Including dyld")
                cpioCmd += " && mkdir -p \(ramdiskRoot.path)/usr/lib"
                // Extract x86_64 slice from dyld
                cpioCmd +=
                    " && lipo -thin x86_64 \(dyldPath) -output \(ramdiskRoot.path)/usr/lib/dyld 2>/dev/null || cp \(dyldPath) \(ramdiskRoot.path)/usr/lib/dyld"
            }
        } else {
            // Use flat binary init
            cpioCmd += " && cp \(initBin.path) \(ramdiskRoot.path)/init"
        }

        cpioCmd += " && cd \(ramdiskRoot.path) && find * | cpio -o -H newc > \(ramdiskCpio.path)"

        try run("/bin/sh", ["-c", cpioCmd])

        // Collect all kernel .o files
        let kernelBuildDir = buildDir.appendingPathComponent("Kernel.build")
        let kernelObjects: [String]
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: kernelBuildDir.path)
            kernelObjects = files.filter { $0.hasSuffix(".o") }.map {
                kernelBuildDir.appendingPathComponent($0).path
            }
        } catch {
            print("Warning: Could not list kernel build dir, using known files")
            kernelObjects = [
                "CPIO.swift.o", "KernelMain.swift.o", "Multiboot.swift.o",
                "virtio_gpu.swift.o", "MachO.swift.o", "Syscall.swift.o", "MachIPC.swift.o",
            ].map { kernelBuildDir.appendingPathComponent($0).path }
        }

        print("Linking Kernel (\(kernelObjects.count) objects)...")
        var linkArgs = [
            "-T",
            context.package.directoryURL.appendingPathComponent("Sources/Boot/linker.ld").path,
            "-o", kernelElf64.path,
        ]
        linkArgs += kernelObjects
        linkArgs += [
            buildDir.appendingPathComponent("Boot.build/boot.S.o").path,
            buildDir.appendingPathComponent("CSupport.build/runtime.c.o").path,
            "--nostdlib", "-static",
        ]
        try run("\(toolchainPath)/ld.lld", linkArgs)

        print("Creating kernel (elf32)...")
        try run(
            "\(toolchainPath)/llvm-objcopy",
            ["-I", "elf64-x86-64", "-O", "elf32-i386", kernelElf64.path, kernelElf32.path])

        if let scPath = sharedCachePath {
            print("Creating disk.img with shared cache...")
            let diskCmd =
                "rm -f \(diskImg.path) && dd if=/dev/zero of=\(diskImg.path) bs=1M count=1 && dd if=\(scPath) of=\(diskImg.path) bs=1M seek=1"
            try run("/bin/sh", ["-c", diskCmd])
        }

        print("\nBuild Completed!")
        print("Kernel: \(kernelElf32.path)")
        print("Ramdisk: \(ramdiskCpio.path)")
        if FileManager.default.fileExists(atPath: diskImg.path) {
            print("Disk: \(diskImg.path)")
        }
        print("\nTo run:")
        var qemu =
            "qemu-system-x86_64 -cpu max -kernel \(kernelElf32.path) -initrd \(ramdiskCpio.path) -serial stdio -display none -m 512"
        if FileManager.default.fileExists(atPath: diskImg.path) {
            qemu += " -drive file=\(diskImg.path),if=virtio,format=raw"
        }
        print(qemu)
    }
}
