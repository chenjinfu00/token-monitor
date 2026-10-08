import Foundation
import Darwin

// The operating system releases this lock on exit, including crashes. The
// file stays in place so every application copy locks the same inode.
final class SingleInstanceLock {
    static let revealNotificationName = Notification.Name("local.tokenmonitor.widget.revealExisting")
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(directory: URL? = nil) throws -> SingleInstanceLock? {
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Token Monitor", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = support.appendingPathComponent("instance.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 {
            return SingleInstanceLock(descriptor: descriptor)
        }
        let failure = errno
        Darwin.close(descriptor)
        if failure == EACCES || failure == EWOULDBLOCK || failure == EAGAIN { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }

    deinit {
        Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
    }
}
