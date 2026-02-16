import CSupport

func findFile(in ramdisk: UnsafeRawPointer, size: Int, named target: StaticString) -> (
    data: UnsafeRawPointer, size: Int
)? {
    var ptr = ramdisk
    let end = ramdisk.advanced(by: size)
    while ptr < end {
        let raw = ptr.assumingMemoryBound(to: UInt8.self)
        // CPIO magic "070701"
        if raw[0] != 48 || raw[1] != 55 || raw[2] != 48 || raw[3] != 55 || raw[4] != 48
            || raw[5] != 49
        {
            break
        }
        let ns = parseHex(raw.advanced(by: 94), length: 8)
        let fs = parseHex(raw.advanced(by: 54), length: 8)
        let namePtr = raw.advanced(by: 110)
        var match = true
        let tPtr = target.utf8Start
        if Int(ns) < target.utf8CodeUnitCount {
            match = false
        } else {
            for i in 0..<target.utf8CodeUnitCount {
                if namePtr[i] != tPtr[i] {
                    match = false
                    break
                }
            }
        }
        let headerAndNameSize = 110 + Int(ns)
        let paddedHeaderSize = (headerAndNameSize + 3) & ~3
        let dataPtr = ptr.advanced(by: paddedHeaderSize)
        if match { return (dataPtr, Int(fs)) }
        ptr = dataPtr.advanced(by: (Int(fs) + 3) & ~3)
        // Trailer check "TRAILER!!!"
        if fs == 0 && ns == 11 && namePtr[0] == 84 { break }
    }
    return nil
}

func parseHex(_ s: UnsafeRawPointer, length: Int) -> Int {
    var result: UInt32 = 0
    let p = s.assumingMemoryBound(to: UInt8.self)
    for i in 0..<length {
        let c = p[i]
        let val: UInt32
        if c >= 48 && c <= 57 {
            val = UInt32(c - 48)
        } else if c >= 65 && c <= 70 {
            val = UInt32(c - 55)
        } else if c >= 97 && c <= 102 {
            val = UInt32(c - 87)
        } else {
            val = 0
        }
        result = (result << 4) | val
    }
    return Int(result)
}
