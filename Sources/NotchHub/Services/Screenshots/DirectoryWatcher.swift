import Foundation

/// Something that happened to a watched directory.
enum DirectoryChange: Sendable, Equatable {
    /// Its contents changed. Worth a scan.
    case changed
    /// The directory this watcher was holding is gone — deleted, renamed, or
    /// its filesystem unmounted. The descriptor now refers to nothing useful,
    /// so the watch has to be re-armed by path.
    case vanished
    /// The directory could not be watched at all.
    case failed(String)
}

/// Watching one directory, abstracted so tests can drive the service without a
/// real folder, a real descriptor, or a real event.
protocol DirectoryWatching: AnyObject, Sendable {
    func start(_ url: URL, onChange: @escaping @Sendable (DirectoryChange) -> Void)
    func stop()
}

/// Watches a single directory with a GCD file-system source.
///
/// **Descriptor ownership.** One serial queue owns the descriptor for its whole
/// life. It is opened on `queue`, stored on `queue`, and closed in exactly one
/// place — the source's cancel handler, which GCD runs once, on `queue`, after
/// any in-flight event handler has returned. Nothing outside this file ever
/// sees the descriptor, and no other thread ever touches it. That is what makes
/// `stop()` race-free rather than merely lucky: it does not close anything, it
/// asks the source to, and `cancel()` is idempotent and thread-safe.
///
/// Two traps worth stating, because both are silent:
///  - a source that is created and released without ever being resumed never
///    runs its cancel handler, and the descriptor leaks. So the order is always
///    create → set handlers → `resume()`, and `cancel()` only ever after that.
///  - `suspend()` has the same effect. This watcher never suspends.
///
/// `@unchecked Sendable` for the same reason `RunningProcess` is: the mutable
/// state is reachable from more than one isolation domain in principle, and is
/// touched from exactly one queue in practice, which the type enforces by never
/// exposing it.
///
/// Note on what this does *not* have to catch: if a different directory is
/// moved on top of the watched path, this descriptor is never touched and no
/// event arrives. The service's periodic reconcile scans by path, so a stale
/// watch can delay a screenshot but cannot lose one.
final class DirectoryWatcher: DirectoryWatching, @unchecked Sendable {

    /// The one owner of the descriptor.
    private let queue = DispatchQueue(label: "com.notchhub.screenshot-watch")

    // Both touched only on `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1

    /// Events that mean "the thing I am holding is not the folder any more".
    ///
    /// Computed rather than stored: `FileSystemEvent` is not `Sendable`, so a
    /// static `let` would be shared mutable state under strict concurrency.
    private static var vanishMask: DispatchSource.FileSystemEvent { [.delete, .rename, .revoke] }

    func start(_ url: URL, onChange: @escaping @Sendable (DirectoryChange) -> Void) {
        queue.async { [self] in
            disarm()
            arm(url, onChange: onChange)
        }
    }

    func stop() {
        queue.async { [self] in disarm() }
    }

    deinit {
        // The source outlives this object until its cancel handler runs, which
        // is exactly what closes the descriptor. Cancelling here rather than
        // closing keeps the single-owner rule intact even at teardown.
        source?.cancel()
    }

    private func arm(_ url: URL, onChange: @escaping @Sendable (DirectoryChange) -> Void) {
        // `O_EVTONLY` opens for notification only — no read intent — but it is
        // still a file-system access, so macOS may put up the folder-permission
        // dialog and block here. That is why this runs on the watch queue and
        // never on the main actor: the notch panel is always on screen, and a
        // main-actor open would freeze it behind the prompt.
        let opened = open(url.path, O_EVTONLY)
        guard opened >= 0 else {
            let code = errno
            onChange(.failed(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription))
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: opened,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let mask = self?.source?.data else { return }
            onChange(mask.isDisjoint(with: Self.vanishMask) ? .changed : .vanished)
        }
        // The single close site.
        source.setCancelHandler { close(opened) }

        descriptor = opened
        self.source = source
        source.resume()
    }

    private func disarm() {
        source?.cancel()
        source = nil
        descriptor = -1
    }
}
