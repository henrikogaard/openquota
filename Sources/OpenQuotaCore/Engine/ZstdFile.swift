import Foundation
import libzstd

/// Reads a zstd-compressed file as a stream of decompressed chunks, so a
/// large archive never has to fit in memory.
enum ZstdFile {
    struct Failure: Error, Equatable {
        var description: String
    }

    /// Calls `body` with each decompressed chunk, in order. Throws when the
    /// data is not valid zstd, ends mid-frame, or would decompress to more
    /// than `maxOutput` bytes; chunks delivered before that stay delivered.
    static func read(_ url: URL, maxOutput: Int, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let stream = ZSTD_createDStream() else { throw Failure(description: "no decompressor") }
        defer { ZSTD_freeDStream(stream) }
        var output = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var total = 0
        // Zero once a frame is complete; anything else at the end is a cut-off file.
        var pending = 0
        while true {
            let chunk = try handle.read(upToCount: 131_072) ?? Data()
            if chunk.isEmpty { break }
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var input = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
                var filled = false
                // Also runs again when the output buffer was filled: more may be waiting.
                while input.pos < input.size || filled {
                    let produced: Int = try output.withUnsafeMutableBytes { buffer in
                        var out = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                        let result = ZSTD_decompressStream(stream, &out, &input)
                        guard ZSTD_isError(result) == 0 else {
                            throw Failure(description: String(cString: ZSTD_getErrorName(result)))
                        }
                        pending = result
                        return out.pos
                    }
                    filled = produced == output.count
                    total += produced
                    guard total <= maxOutput else { throw Failure(description: "too large") }
                    if produced > 0 { try body(Data(output[0..<produced])) }
                }
            }
        }
        guard pending == 0 else { throw Failure(description: "incomplete") }
    }
}
