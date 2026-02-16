# Xarwin OS

A XNU-compatible operating system written in Swift.

## Building and Running

```sh
swift build --triple x86_64-unknown-none-elf && swift package --allow-writing-to-package-directory build-image
```

## Running

```sh
# Interactive (serial on stdio)
qemu-system-x86_64 -cpu max -kernel .build/x86_64-unknown-none-elf/debug/kernel -initrd .build/x86_64-unknown-none-elf/debug/ramdisk.cpio -serial mon:stdio -display none -m 4G

# Log to file
qemu-system-x86_64 -cpu max -kernel .build/x86_64-unknown-none-elf/debug/kernel -initrd .build/x86_64-unknown-none-elf/debug/ramdisk.cpio -serial file:/tmp/serial.log -display none -m 4G 
```
