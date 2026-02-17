with open("zig-out/bin/kernel", "rb") as f:
    data = f.read()
    magic = b"\x02\xb0\xad\x1b"
    offset = data.find(magic)
    if offset != -1:
        print(f"Found magic at offset: {offset}")
    else:
        print("Magic not found")
