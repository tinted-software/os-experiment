#!/bin/bash
set -e

# Create ramdisk if it doesn't exist or is outdated
if [ ! -f ramdisk.cpio ] || [ ../kernel/dyld_thin -nt ramdisk.cpio ]; then
    echo "Creating ramdisk.cpio..."
    mkdir -p ramdisk_root/usr/lib
    cp ../kernel/dyld_thin ramdisk_root/usr/lib/dyld
    cd ramdisk_root && find * | cpio -o -H newc > ../ramdisk.cpio
    cd ..
    rm -rf ramdisk_root
fi

echo "Building kernel..."
# Build the kernel using Zig build
zig build

echo "Kernel built. Checking offset..."
if [ -f zig-out/bin/kernel ]; then
    python3 -c "import sys; f=open('zig-out/bin/kernel', 'rb'); data=f.read(); offset=data.find(b'\xd6\x50\x52\xe8'); print(f'Multiboot 2 header offset: {offset}')"
else
    echo "Error: zig-out/bin/kernel not found!"
    exit 1
fi

echo "Converting to 32-bit ELF..."
# Convert to 32-bit ELF for Multiboot compatibility
llvm-objcopy -I elf64-x86-64 -O elf32-i386 zig-out/bin/kernel kernel32.elf

echo "Running QEMU..."
# Run in QEMU
qemu-system-x86_64 -cpu max \
    -kernel kernel32.elf \
    -initrd ramdisk.cpio \
    -serial mon:stdio \
    -display none \
    -m 1G
