/*
 This project is based on part the Swift Package Manager project.
 The original bears the following disclaimer:

 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

#if os(Linux)
import Glibc
#else
import Darwin
#endif

import Dispatch

/// Convert an integer in 0..<16 to its hexadecimal ASCII character.
private func hexdigit(_ value: UInt8) -> UInt8 {
    return value < 10 ? (0x30 + value) : (0x40 + value - 10)
}

/// Describes a type which can be written to a byte stream.
public protocol ByteStreamable {
    func write(to stream: OutputByteStream)
}

/// An output byte stream.
///
/// This protocol is designed to be able to support efficient streaming to
/// different output destinations, e.g., a file or an in memory buffer. This is
/// loosely modeled on LLVM's llvm::raw_ostream class.
///
/// The stream is generally used in conjunction with the custom streaming
/// operator '<<<'. For example:
///
///   let stream = BufferedOutputByteStream()
///   stream <<< "Hello, world!"
///
/// would write the UTF8 encoding of "Hello, world!" to the stream.
///
/// The stream accepts a number of custom formatting operators which are defined
/// in the `Format` struct (used for namespacing purposes). For example:
///
///   let items = ["hello", "world"]
///   stream <<< Format.asSeparatedList(items, separator: " ")
///
/// would write each item in the list to the stream, separating them with a
/// space.
public protocol OutputByteStream: class, TextOutputStream {
    /// The current offset within the output stream.
    var position: Int { get }

    /// Write an individual byte to the buffer.
    func write(_ byte: UInt8)

    /// Write a collection of bytes to the buffer.
    func write<C: Collection>(_ bytes: C) where C.Element == UInt8

    /// Flush the stream's buffer.
    func flush()
}

extension OutputByteStream {
    /// Write a sequence of bytes to the buffer.
    public func write<S: Sequence>(sequence: S) where S.Element == UInt8 {
        #if swift(>=5.0)
        guard let _ = sequence.withContiguousStorageIfAvailable(self.write(_:)) else {
            sequence.forEach(self.write(_:))
        }
        #else
        // Iterate the sequence and append byte-by-byte since sequence's append
        // is not performant anyway.
        for byte in sequence {
            write(byte)
        }
        #endif
    }

    /// Write a string to the buffer (as UTF8).
    public func write(_ string: String) {
        write(string.utf8)
    }
}

/// The `OutputByteStream` base class.
///
/// This class provides a base and efficient implementation of the `OutputByteStream`
/// protocol. It can not be used as is-as subclasses as several functions need to be
/// implemented in subclasses.
public class _OutputByteStreamBase: OutputByteStream {
    /// If buffering is enabled.
    @usableFromInline
    let _buffered: Bool

    /// The data buffer.
    /// - Note: Minimum buffer size should be `1`.
    @usableFromInline
    var _buffer: [UInt8]

    /// Default buffer size of the data buffer.
    private static let bufferSize = 1024

    /// Queue to protect mutations.
    fileprivate let queue = DispatchQueue(label: "org.swift.swiftpm.basic.stream")

    init(buffered: Bool) {
        self._buffered = buffered
        self._buffer = []

        // When not buffered we still reserve 1 byte, as it is used by the
        // single-byte write() variant.
        self._buffer.reserveCapacity(buffered ? _OutputByteStreamBase.bufferSize : 1)
    }

    // MARK: Data Access API

    /// The current offset within the output stream.
    public var position: Int {
        return _buffer.count
    }

    /// Currently available buffer size.
    @usableFromInline
    var _availableBufferSize: Int {
        return _buffer.capacity - _buffer.count
    }

    /// Clears the buffer maintaining current capacity.
    @usableFromInline
    func _clearBuffer() {
        _buffer.removeAll(keepingCapacity: true)
    }

    // MARK: Data Output API

    public final func flush() {
        writeImpl(ArraySlice(_buffer))
        _clearBuffer()
        flushImpl()
    }

    @usableFromInline
    func flushImpl() {
        // Does nothing.
    }

    @usableFromInline
    func writeImpl<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        fatalError("Subclasses must implement this")
    }

    @usableFromInline
    func writeImpl(_ bytes: ArraySlice<UInt8>) {
        fatalError("Subclasses must implement this")
    }

    /// Write an individual byte to the buffer.
    public final func write(_ byte: UInt8) {
        guard _buffered else {
            _buffer.append(byte)
            writeImpl(ArraySlice(_buffer))
            flushImpl()
            _clearBuffer()
            return
        }

        // If buffer is full, write and clear it.
        if _availableBufferSize == 0 {
            writeImpl(ArraySlice(_buffer))
            _clearBuffer()
        }

        // This will need to change if we ever have an unbuffered stream.
        precondition(_availableBufferSize > 0)
        _buffer.append(byte)
    }

    /// Write a collection of bytes to the buffer.
    @inlinable
    public final func write<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        guard _buffered else {
            if let b = bytes as? ArraySlice<UInt8> {
                // Fast path for unbuffered ArraySlice
                writeImpl(b)
            } else if let b = bytes as? Array<UInt8> {
                // Fast path for unbuffered Array
                writeImpl(ArraySlice(b))
            } else {
                // generic collection unfortunately must be temporarily buffered
                writeImpl(bytes)
            }
            flushImpl()
            return
        }

        // This is based on LLVM's raw_ostream.
        let availableBufferSize = self._availableBufferSize
        let byteCount = Int(bytes.count)

        // If we have to insert more than the available space in the buffer.
        if byteCount > availableBufferSize {
            // If buffer is empty, start writing and keep the last chunk in the buffer.
            if _buffer.isEmpty {
                let bytesToWrite = byteCount - (byteCount % availableBufferSize)
                let writeUptoIndex = bytes.index(bytes.startIndex, offsetBy: numericCast(bytesToWrite))
                writeImpl(bytes.prefix(upTo: writeUptoIndex))

                // If remaining bytes is more than buffer size write everything.
                let bytesRemaining = byteCount - bytesToWrite
                if bytesRemaining > availableBufferSize {
                    writeImpl(bytes.suffix(from: writeUptoIndex))
                    return
                }

                // Otherwise, keep remainder in buffer.
                _buffer += bytes.suffix(from: writeUptoIndex)
                return
            }

            let writeUptoIndex = bytes.index(bytes.startIndex, offsetBy: numericCast(availableBufferSize))
            // Append whatever we can accomodate.
            _buffer += bytes.prefix(upTo: writeUptoIndex)

            writeImpl(ArraySlice(_buffer))
            _clearBuffer()

            // FIXME: We rhould start again with remaining chunk but this doesn't work. Write everything
            // for now.
            writeImpl(bytes.suffix(from: writeUptoIndex))
            return
        }

        _buffer += bytes
    }
}

/// The thread-safe wrapper around output byte streams.
///
/// This class wraps any `OutputByteStream` conforming type to provide a type-safe
/// access to its operations. If the provided stream inherits from `_OutputByteStreamBase`,
/// it will also ensure it is type-safe will all other `ThreadSafeOutputByteStream` instances
/// around the same stream.
public final class ThreadSafeOutputByteStream: OutputByteStream {
    private static let defaultQueue = DispatchQueue(label: "org.swift.swiftpm.basic.thread-safe-output-byte-stream")
    public let stream: OutputByteStream
    private let queue: DispatchQueue

    public var position: Int {
        return queue.sync { stream.position }
    }

    public init(_ stream: OutputByteStream) {
        self.stream = stream
        self.queue = (stream as? _OutputByteStreamBase)?.queue ?? ThreadSafeOutputByteStream.defaultQueue
    }

    public func write(_ byte: UInt8) {
        queue.sync { stream.write(byte) }
    }

    public func write<C>(_ bytes: C) where C : Collection, C.Element == UInt8 {
        queue.sync { stream.write(bytes) }
    }

    public func flush() {
        queue.sync{ stream.flush() }
    }

    public func write<S>(sequence: S) where S : Sequence, S.Element == UInt8 {
        queue.sync { stream.write(sequence: sequence) }
    }
}

/// Define an output stream operator. We need it to be left-associative, so we
/// use `<<<`.
infix operator <<< : StreamingPrecedence
precedencegroup StreamingPrecedence {
    associativity: left
}

// MARK: Output Operator Implementations

// FIXME: This override shouldn't be necesary but removing it causes a 30% performance regression. This problem is
// tracked by the following bug: https://bugs.swift.org/browse/SR-8535
@discardableResult
public func <<< (stream: OutputByteStream, value: ArraySlice<UInt8>) -> OutputByteStream {
    value.write(to: stream)
    return stream
}

@discardableResult
public func <<< (stream: OutputByteStream, value: ByteStreamable) -> OutputByteStream {
    value.write(to: stream)
    return stream
}

@discardableResult
public func <<< (stream: OutputByteStream, value: CustomStringConvertible) -> OutputByteStream {
    value.description.write(to: stream)
    return stream
}

@discardableResult
public func <<< (stream: OutputByteStream, value: ByteStreamable & CustomStringConvertible) -> OutputByteStream {
    value.write(to: stream)
    return stream
}

extension UInt8: ByteStreamable {
    public func write(to stream: OutputByteStream) {
        stream.write(self)
    }
}

extension Character: ByteStreamable {
    public func write(to stream: OutputByteStream) {
        stream.write(String(self))
    }
}

extension String: ByteStreamable {
    public func write(to stream: OutputByteStream) {
        stream.write(utf8)
    }
}

extension Substring: ByteStreamable {
    public func write(to stream: OutputByteStream) {
        stream.write(utf8)
    }
}

extension StaticString: ByteStreamable {
    public func write(to stream: OutputByteStream) {
        withUTF8Buffer { stream.write($0) }
    }
}

extension Array: ByteStreamable where Element == UInt8 {
    public func write(to stream: OutputByteStream) {
        stream.write(self)
    }
}

extension ArraySlice: ByteStreamable where Element == UInt8 {
    public func write(to stream: OutputByteStream) {
        stream.write(self)
    }
}

extension ContiguousArray: ByteStreamable where Element == UInt8 {
    public func write(to stream: OutputByteStream) {
        stream.write(self)
    }
}

// MARK: Formatted Streaming Output

/// Provides operations for returning derived streamable objects to
/// implement various forms of formatted output.
public struct Format {
    /// Write the input list to the stream with the given separator between items.
    public static func asSeparatedList<T: ByteStreamable>(_ items: [T], separator: String) -> ByteStreamable {
        return SeparatedListStreamable(items: items, separator: separator)
    }
    private struct SeparatedListStreamable<T: ByteStreamable>: ByteStreamable {
        let items: [T]
        let separator: String

        func write(to stream: OutputByteStream) {
            for (i, item) in items.enumerated() {
                // Add the separator if necessary.
                if i != 0 {
                    stream <<< separator
                }
                stream <<< item
            }
        }
    }

    /// Write the input list to the stream (after applying a transform to each item)
    /// with the given separator between items.
    public static func asSeparatedList<T>(_ items: [T], transform: @escaping (T) -> ByteStreamable,
                                          separator: String) -> ByteStreamable {
        return TransformedSeparatedListStreamable(items: items, transform: transform, separator: separator)
    }
    private struct TransformedSeparatedListStreamable<T>: ByteStreamable {
        let items: [T]
        let transform: (T) -> ByteStreamable
        let separator: String

        func write(to stream: OutputByteStream) {
            for (i, item) in items.enumerated() {
                if i != 0 { stream <<< separator }
                stream <<< transform(item)
            }
        }
    }

    public static func asRepeating(string: String, count: Int) -> ByteStreamable {
        precondition(count >= 0, "Count should be >= zero")
        return RepeatingStringStreamable(string: string, count: count)
    }
    private struct RepeatingStringStreamable: ByteStreamable {
        let string: String
        let count: Int

        func write(to stream: OutputByteStream) {
            for _ in 0 ..< count {
                stream <<< string
            }
        }
    }
}

/// In-memory implementation of OutputByteStream.
public final class BufferedOutputByteStream: _OutputByteStreamBase {
    /// Contents of the stream.
    private var contents = [UInt8]()

    public init() {
        // We disable the buffering of the underlying _OutputByteStreamBase as
        // we are explicitly buffering the whole stream in memory.
        super.init(buffered: false)
    }

    /// The contents of the output stream.
    ///
    /// - Note: This implicitly flushes the stream.
    public var bytes: ByteString {
        flush()
        return ByteString(contents)
    }

    /// The current offset within the output stream.
    public override final var position: Int {
        return contents.count
    }

    override final func flushImpl() {
        // Do nothing.
    }

    override final func writeImpl<C>(_ bytes: C) where C : Collection, C.Element == UInt8 {
        contents += bytes
    }

    override final func writeImpl(_ bytes: ArraySlice<UInt8>) {
        contents += bytes
    }
}

/// Represents a stream which is backed to a file. Not for instantiating.
public class FileOutputByteStream: _OutputByteStreamBase {
    /// Closes the file, flushing any buffered data.
    public final func close() throws {
        flush()
        try closeImpl()
    }

    func closeImpl() throws {
        fatalError("closeImpl() should be implemented by a subclass")
    }
}

/// Implements file output stream for local file system.
public final class LocalFileOutputByteStream: FileOutputByteStream {
    /// The pointer to the file.
    let filePointer: UnsafeMutablePointer<FILE>

    /// True if there were any IO errors while writing.
    private var error: Bool = false

    /// Closes the file on deinit if true.
    private var closeOnDeinit: Bool

    /// Instantiate using the file pointer.
    init(filePointer: UnsafeMutablePointer<FILE>, closeOnDeinit: Bool = true,
         buffered: Bool = true) throws {
        self.filePointer = filePointer
        self.closeOnDeinit = closeOnDeinit
        super.init(buffered: buffered)
    }

    /// Opens the file for writing at the provided path.
    ///
    /// - Parameters:
    ///     - path: Path to the file this stream should operate on.
    ///     - closeOnDeinit: If true closes the file on deinit. clients can use
    ///                      close() if they want to close themselves or catch
    ///                      errors encountered during writing to the file.
    ///                      Default value is true.
    ///     - buffered: If true buffers writes in memory until full or flush().
    ///                 Otherwise, writes are processed and flushed immediately.
    ///                 Default value is true.
    ///
    /// - Throws: UnixError
    public init(_ path: String, closeOnDeinit: Bool = true, buffered: Bool = true) throws {
        guard let filePointer = fopen(path, "wb") else {
            throw FileSystemError(errno: errno)
        }
        self.filePointer = filePointer
        self.closeOnDeinit = closeOnDeinit
        super.init(buffered: buffered)
    }

    deinit {
        if closeOnDeinit {
            fclose(filePointer)
        }
    }

    func errorDetected() {
        error = true
    }

    override final func writeImpl<C>(_ bytes: C) where C : Collection, C.Element == UInt8 {
        var contents = [UInt8](bytes)
        while true {
            let n = fwrite(&contents, 1, contents.count, filePointer)
            if n < 0 {
                if errno == EINTR { continue }
                errorDetected()
            } else if n != contents.count {
                errorDetected()
            }
            break
        }
    }

    override final func writeImpl(_ bytes: ArraySlice<UInt8>) {
        bytes.withUnsafeBytes { bytesPtr in
            while true {
                let n = fwrite(bytesPtr.baseAddress, 1, bytesPtr.count, filePointer)
                if n < 0 {
                    if errno == EINTR { continue }
                    errorDetected()
                } else if n != bytesPtr.count {
                    errorDetected()
                }
                break
            }
        }
    }

    override final func flushImpl() {
        fflush(filePointer)
    }

    override final func closeImpl() throws {
        defer {
            fclose(filePointer)
            closeOnDeinit = false
        }

        // Throw if errors were found during writing.
        if error {
            throw FileSystemError.ioError
        }
    }
}

/// Public stdout stream instance.
public var stdoutStream: ThreadSafeOutputByteStream = try! ThreadSafeOutputByteStream(LocalFileOutputByteStream(filePointer: stdout, closeOnDeinit: false))

/// Public stderr stream instance.
public var stderrStream: ThreadSafeOutputByteStream = try! ThreadSafeOutputByteStream(LocalFileOutputByteStream(filePointer: stderr, closeOnDeinit: false))

public enum FileSystemError: Swift.Error {
    /// Access to the path is denied.
    ///
    /// This is used when an operation cannot be completed because a component of
    /// the path cannot be accessed.
    ///
    /// Used in situations that correspond to the POSIX EACCES error code.
    case invalidAccess

    /// Invalid encoding
    ///
    /// This is used when an operation cannot be completed because a path could
    /// not be decoded correctly.
    case invalidEncoding

    /// IO Error encoding
    ///
    /// This is used when an operation cannot be completed due to an otherwise
    /// unspecified IO error.
    case ioError

    /// Is a directory
    ///
    /// This is used when an operation cannot be completed because a component
    /// of the path which was expected to be a file was not.
    ///
    /// Used in situations that correspond to the POSIX EISDIR error code.
    case isDirectory

    /// No such path exists.
    ///
    /// This is used when a path specified does not exist, but it was expected
    /// to.
    ///
    /// Used in situations that correspond to the POSIX ENOENT error code.
    case noEntry

    /// Not a directory
    ///
    /// This is used when an operation cannot be completed because a component
    /// of the path which was expected to be a directory was not.
    ///
    /// Used in situations that correspond to the POSIX ENOTDIR error code.
    case notDirectory

    /// Unsupported operation
    ///
    /// This is used when an operation is not supported by the concrete file
    /// system implementation.
    case unsupported

    /// An unspecific operating system error.
    case unknownOSError
}

extension FileSystemError {
    init(errno: Int32) {
        switch errno {
        case EACCES:
            self = .invalidAccess
        case EISDIR:
            self = .isDirectory
        case ENOENT:
            self = .noEntry
        case ENOTDIR:
            self = .notDirectory
        default:
            self = .unknownOSError
        }
    }
}
