import CoreServices
import DockyardCore
import Foundation

/// File system changes under a folder, from FSEvents, as the `WatchEvent`s the watch coordinator expects.
///
/// FSEvents reports what happened to a path, not what became of it: whether a path still exists decides between
/// "changed" and "deleted", and renames arrive as a delete of the old name plus a create of the new one.
final class FSEventsSource: @unchecked Sendable {
    private let root: String
    private let continuation: AsyncStream<WatchEvent>.Continuation
    private let queue = DispatchQueue(label: "app.dockyard.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    static func events(for path: String) -> AsyncStream<WatchEvent> {
        let (stream, continuation) = AsyncStream<WatchEvent>.makeStream(bufferingPolicy: .unbounded)
        let source = FSEventsSource(root: path, continuation: continuation)
        source.start()
        continuation.onTermination = { _ in source.stop() }
        return stream
    }

    private init(root: String, continuation: AsyncStream<WatchEvent>.Continuation) {
        self.root = root
        self.continuation = continuation
    }

    private func start() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let source = Unmanaged<FSEventsSource>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: rawFlags, count: count))
            source.handle(paths, flags)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            continuation.finish()
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    private func stop() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func handle(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let isDirectory = UInt32(kFSEventStreamEventFlagItemIsDir)
        let created = UInt32(kFSEventStreamEventFlagItemCreated)
        let relevant = UInt32(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemModified)
        for (path, flag) in zip(paths, flags) where flag & relevant != 0 {
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            if exists {
                continuation.yield(WatchEvent(path: path, kind: flag & created != 0 ? .created : .modified, isDirectory: directory.boolValue))
            } else {
                continuation.yield(WatchEvent(path: path, kind: .deleted, isDirectory: flag & isDirectory != 0))
            }
        }
    }
}
