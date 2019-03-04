/*
 This project is based on part the Swift Package Manager project.
 The original bears the following disclaimer:

 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

/// A `ByteString` represents a sequence of bytes.
///
/// This struct provides useful operations for working with buffers of
/// bytes. Conceptually it is just a contiguous array of bytes (UInt8), but it
/// contains methods and default behavor suitable for common operations done
/// using bytes strings.
///
/// This struct *is not* intended to be used for significant mutation of byte
/// strings, we wish to retain the flexibility to micro-optimize the memory
/// allocation of the storage (for example, by inlining the storage for small
/// strings or and by eliminating wasted space in growable arrays). For
/// construction of byte arrays, clients should use the `OutputByteStream` class
/// and then convert to a `ByteString` when complete.
public struct ByteString: ExpressibleByArrayLiteral, Hashable {
    /// The buffer contents.
    fileprivate var _bytes: [UInt8]

    /// Create an empty byte string.
    public init() {
        _bytes = []
    }

    /// Create a byte string from a byte array literal.
    public init(arrayLiteral contents: UInt8...) {
        _bytes = contents
    }

    /// Create a byte string from an array of bytes.
    public init(_ contents: [UInt8]) {
        _bytes = contents
    }

    /// Create a byte string from a byte buffer.
    public init<S: Sequence>(_ contents: S) where S.Element == UInt8 {
        _bytes = [UInt8](contents)
    }

    /// Create a byte string from the UTF8 encoding of a string.
    public init(encodingAsUTF8 string: String) {
        _bytes = [UInt8](string.utf8)
    }

    /// Access the byte string contents as an array.
    public var contents: [UInt8] {
        return _bytes
    }

    /// Return the byte string size.
    public var count: Int {
        return _bytes.count
    }
}

extension ByteString: CustomStringConvertible {
    /// Returns the string decoded as a UTF-8 sequence, or traps if not possible.
    public var description: String {
        guard let description = validDescription else {
            fatalError("invalid byte string: \(cString)")
        }
        return description
    }

    /// Returns the string decoded as a UTF-8 sequence, if possible.
    public var validDescription: String? {
        return String(bytes: _bytes, encoding: .utf8)
    }

    /// Return the string decoded as a UTF-8 sequence, substituting replacement
    /// characters for ill-formed UTF-8 sequences.
    public var cString: String {
        let tmp = _bytes + [UInt8(0)]
        return tmp.withUnsafeBufferPointer { ptr in
            return String(cString: unsafeBitCast(ptr.baseAddress, to: UnsafePointer<CChar>.self))
        }
    }
}

extension ByteString: ByteStreamable {
    public func write(to stream: OutputByteStream) {
        stream.write(_bytes)
    }
}

extension ByteString: ExpressibleByStringLiteral {
    public typealias UnicodeScalarLiteralType = StringLiteralType
    public typealias ExtendedGraphemeClusterLiteralType = StringLiteralType

    public init(unicodeScalarLiteral value: UnicodeScalarLiteralType) {
        _bytes = [UInt8](value.utf8)
    }
    public init(extendedGraphemeClusterLiteral value: ExtendedGraphemeClusterLiteralType) {
        _bytes = [UInt8](value.utf8)
    }
    public init(stringLiteral value: StringLiteralType) {
        _bytes = [UInt8](value.utf8)
    }
}
