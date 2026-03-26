import Foundation
import Compression

/// 将 JSON 等 Data 压缩为 gzip 格式（火山引擎首包要求）
enum Gzip {
    /// 固定 gzip 头：无额外字段，默认压缩
    private static let gzipHeader: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03]

    static func compress(_ data: Data) -> Data? {
        // 使用 Compression 的 zlib 得到 deflate 流，再包装成 gzip
        let dstCapacity = data.count + (data.count / 100) + 64
        var dest = [UInt8](repeating: 0, count: dstCapacity)
        let scratchSize = compression_encode_scratch_buffer_size(COMPRESSION_ZLIB)
        var scratch = [UInt8](repeating: 0, count: scratchSize)
        let written = data.withUnsafeBytes { srcBuf in
            guard let src = srcBuf.baseAddress else { return 0 }
            return compression_encode_buffer(
                &dest, dstCapacity,
                src, data.count,
                &scratch,
                COMPRESSION_ZLIB
            )
        }
        guard written > 0, written <= dstCapacity else { return nil }
        let compressed = Data(dest.prefix(written))
        // Apple COMPRESSION_ZLIB 输出标准 zlib（2 字节头 + deflate + 4 字节 adler），提取 deflate 后包 gzip
        let deflate: Data
        if compressed.count > 6 && compressed[0] == 0x78 {
            deflate = compressed.dropFirst(2).dropLast(4)
        } else {
            deflate = compressed
        }
        let crc = crc32(data)
        let isize = UInt32(truncatingIfNeeded: data.count)
        var out = Data(gzipHeader)
        out.append(deflate)
        out.append(Data([UInt8(crc & 0xff), UInt8((crc >> 8) & 0xff), UInt8((crc >> 16) & 0xff), UInt8((crc >> 24) & 0xff)]))
        out.append(Data([UInt8(isize & 0xff), UInt8((isize >> 8) & 0xff), UInt8((isize >> 16) & 0xff), UInt8((isize >> 24) & 0xff)]))
        return out
    }

    /// 解压 gzip 格式的数据
    static func decompress(_ data: Data) -> Data? {
        // gzip 最少 10 字节头 + 8 字节尾
        guard data.count >= 18, data[0] == 0x1f, data[1] == 0x8b else { return nil }

        // 跳过 gzip header（10 字节固定头，可能有额外字段）
        var offset = 10
        let flg = data[3]
        if (flg & 0x04) != 0 { // FEXTRA
            guard data.count > offset + 2 else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if (flg & 0x08) != 0 { // FNAME
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if (flg & 0x10) != 0 { // FCOMMENT
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if (flg & 0x02) != 0 { offset += 2 } // FHCRC

        guard offset < data.count - 8 else { return nil }

        // 提取 deflate 数据（去掉尾部 8 字节 CRC32 + ISIZE）
        let deflateData = data.subdata(in: offset..<(data.count - 8))

        // 包装成 zlib 格式（2 字节头 + deflate）给 COMPRESSION_ZLIB 解压
        var zlibData = Data([0x78, 0x9C])
        zlibData.append(deflateData)

        let dstCapacity = deflateData.count * 10  // 预估解压后大小
        var dest = [UInt8](repeating: 0, count: dstCapacity)
        let scratchSize = compression_decode_scratch_buffer_size(COMPRESSION_ZLIB)
        var scratch = [UInt8](repeating: 0, count: scratchSize)
        let written = zlibData.withUnsafeBytes { srcBuf in
            guard let src = srcBuf.baseAddress else { return 0 }
            return compression_decode_buffer(
                &dest, dstCapacity,
                src, zlibData.count,
                &scratch,
                COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return Data(dest.prefix(written))
    }

    private static var crcTable: [UInt32] = {
        (0..<256).map { n in
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffffffff
        for b in data {
            c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8)
        }
        return c ^ 0xffffffff
    }
}
