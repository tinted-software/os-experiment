with open("zig-out/bin/kernel", "rb") as f:
    data = f.read()
    magic = b"\xd6\x50\x52\xe8"  # Little endian for 0xe85250d6
    offset = data.find(magic)
    if offset != -1:
        print(f"Found Multiboot 2 magic at offset: {offset}")
        # Print first 32 bytes of the header
        header = data[offset : offset + 32]
        print(f"Header: {header.hex()}")
    else:
        print("Multiboot 2 magic not found")
