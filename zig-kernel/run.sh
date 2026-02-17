#!/usr/bin/env sh
set -e

if [ ! -f ramdisk.cpio ] || [ ../kernel/dyld_thin -nt ramdisk.cpio ]; then
    echo "Creating ramdisk.cpio..."
    mkdir -p ramdisk_root/usr/lib
    cp ../kernel/dyld_thin ramdisk_root/usr/lib/dyld
    cd ramdisk_root && find * | cpio -o -H newc > ../ramdisk.cpio
    cd ..
    rm -rf ramdisk_root
fi

echo "Building kernel..."
zig build

echo "Converting to 32-bit ELF..."
llvm-objcopy -I elf64-x86-64 -O elf32-i386 zig-out/bin/kernel kernel32.elf

echo "Running QEMU..."
qemu-system-x86_64 -cpu max \
    -kernel kernel32.elf \
    -initrd ramdisk.cpio \
    -serial mon:stdio \
    -display none \
    -m 1G
