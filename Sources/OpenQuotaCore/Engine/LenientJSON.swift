import Foundation

/// JSON parsing that accepts a zero written with a huge exponent, such as
/// `0E-6176`. OpenAI's cost API sends that for empty amounts (a 128-bit
/// decimal zero), and Foundation rejects the whole document over it.
enum LenientJSON {
    static func object(with data: Data) -> Any? {
        if let value = try? JSONSerialization.jsonObject(with: data) { return value }
        return try? JSONSerialization.jsonObject(with: rewritingZeroExponents(data))
    }

    /// Rewrites well-formed zero numbers that carry an exponent (`0E-6176`,
    /// `-0.00e+400`) as `0`. Strings and every other token are left alone.
    static func rewritingZeroExponents(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output = Data()
        output.reserveCapacity(bytes.count)
        var index = 0
        var inString = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                output.append(byte)
                if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                    output.append(bytes[index + 1])
                    index += 2
                    continue
                }
                if byte == UInt8(ascii: "\"") { inString = false }
                index += 1
            } else if byte == UInt8(ascii: "\"") {
                inString = true
                output.append(byte)
                index += 1
            } else if byte == UInt8(ascii: "-") || isDigit(byte) {
                var end = index
                while end < bytes.count, isNumberByte(bytes[end]) { end += 1 }
                let token = bytes[index..<end]
                if isZeroWithExponent(token) {
                    output.append(UInt8(ascii: "0"))
                } else {
                    output.append(contentsOf: token)
                }
                index = end
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        isDigit(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
    }

    /// A complete, well-formed JSON number whose value is zero and that has
    /// an exponent: `-?0(\.0+)?[eE][+-]?digits`. Anything else, including a
    /// malformed token that merely starts like one, is left for the parser
    /// to refuse.
    private static func isZeroWithExponent(_ token: ArraySlice<UInt8>) -> Bool {
        var rest = token
        if rest.first == UInt8(ascii: "-") { rest = rest.dropFirst() }
        guard rest.first == UInt8(ascii: "0") else { return false }
        rest = rest.dropFirst()
        if rest.first == UInt8(ascii: ".") {
            rest = rest.dropFirst()
            let zeros = rest.prefix { $0 == UInt8(ascii: "0") }
            guard !zeros.isEmpty else { return false }
            rest = rest.dropFirst(zeros.count)
        }
        guard rest.first == UInt8(ascii: "e") || rest.first == UInt8(ascii: "E") else { return false }
        rest = rest.dropFirst()
        if rest.first == UInt8(ascii: "+") || rest.first == UInt8(ascii: "-") { rest = rest.dropFirst() }
        return !rest.isEmpty && rest.allSatisfy(isDigit)
    }
}
