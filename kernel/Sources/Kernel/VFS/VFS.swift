/*
 * VFS.swift
 * Virtual File System Core Definitions
 */

public enum VNodeType {
    case file
    case directory
    case device
    case symlink
}

public protocol VNode: AnyObject {
    var type: VNodeType { get }
    var name: String { get }
    var parent: VNode? { get }
    var size: UInt64 { get }

    // Directory operations
    func lookup(name: String) -> VNode?
    func readdir() -> [String]

    // File operations
    func read(offset: UInt64, count: Int, buffer: UnsafeMutableRawPointer) -> Int
    func write(offset: UInt64, count: Int, buffer: UnsafeRawPointer) -> Int
    func mmap(offset: UInt64, size: Int) -> UnsafeRawPointer?
    func close()
}

public class FileDescription {
    public let vnode: VNode
    public var offset: UInt64
    public var flags: Int

    public init(vnode: VNode, flags: Int) {
        self.vnode = vnode
        self.offset = 0
        self.flags = flags
    }

    public func read(buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        let bytesRead = vnode.read(offset: offset, count: count, buffer: buffer)
        if bytesRead > 0 {
            offset += UInt64(bytesRead)
        }
        return bytesRead
    }

    public func write(buffer: UnsafeRawPointer, count: Int) -> Int {
        let bytesWritten = vnode.write(offset: offset, count: count, buffer: buffer)
        if bytesWritten > 0 {
            offset += UInt64(bytesWritten)
        }
        return bytesWritten
    }

    public func close() {
        vnode.close()
    }
}

public class VFS {
    nonisolated(unsafe) public static let shared = VFS()
    private var root: VNode?
    private var openFiles: [(Int, FileDescription)] = []
    private var nextFd = 3  // 0, 1, 2 are stdin/out/err

    private init() {}

    public func mount(root: VNode) {
        self.root = root
    }

    public func open(path: String, flags: Int) -> Int? {
        guard let node = resolve(path: path) else { return nil }
        let fd = nextFd
        nextFd += 1
        openFiles.append((fd, FileDescription(vnode: node, flags: flags)))
        return fd
    }

    public func getFileDescription(fd: Int) -> FileDescription? {
        for f in openFiles {
            if f.0 == fd { return f.1 }
        }
        return nil
    }

    public func close(fd: Int) {
        if let idx = openFiles.firstIndex(where: { $0.0 == fd }) {
            openFiles[idx].1.close()
            openFiles.remove(at: idx)
        }
    }

    private func resolve(path: String) -> VNode? {
        // Simple resolution relative to root
        // TODO: Handle absolute/relative paths properly
        guard let root = root else { return nil }

        let components = path.split(separator: "/")
        var current = root
        for component in components {
            if let next = current.lookup(name: String(component)) {
                current = next
            } else {
                return nil
            }
        }
        return current
    }
}
