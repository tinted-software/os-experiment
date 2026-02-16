# Xarwin OS

A XNU-compatible operating system written in Swift.

## Building and Running

```sh
swift build --triple x86_64-unknown-none-elf && swift package --allow-writing-to-package-directory build-image
```

## Running

```sh
qemu-system-x86_64 -kernel /Volumes/Dev/swift-os/.build/x86_64-unknown-none-elf/debug/kernel -initrd /Volumes/Dev/swift-os/.build/x86_64-unknown-none-elf/debug/ramdisk.cpio -serial mon:stdio -device virtio-gpu-pci
```
