import CryptoKit
import Foundation
import zlib

public struct ZIPCompressor: Sendable {
    private let chunkSize = 1_048_576
    public init() {}

    private struct Entry {
        let name: Data
        let offset: UInt64
        let dataOffset: UInt64
        let size: UInt64
        let compressedSize: UInt64
        let crc: UInt32
        let digest: SHA256.Digest
        let time: UInt16
        let date: UInt16
        let directory: Bool
    }

    public func compress(_ files: [InputFile], quality: CompressionQuality, cancellation: CancellationToken,
                         progress: ProgressHandler = { _ in }) throws -> CompressionResult {
        guard !files.isEmpty, files.count <= 10_000 else {
            throw CompressionError.archive("Select between 1 and 10,000 files.")
        }
        try cancellation.check()
        progress(.init(.analyzing, fraction: 0))
        let sources = try ArchivePlanner.expand(files, cancellation: cancellation)
        let workspace = try FileUtilities.makeWorkspace()
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: workspace) } }
        let url = workspace.appendingPathComponent(files.count == 1 ? files[0].url.deletingPathExtension().lastPathComponent + ".zip" : "Pliegue Archive.zip")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CompressionError.archive("Could not create the archive. Check the available disk space.")
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let total = sources.reduce(UInt64(0)) { $0 + $1.file.size }
        var entries: [Entry] = []
        var processed: UInt64 = 0
        for (index, source) in sources.enumerated() {
            let file = source.file
            try file.checkUnchanged()
            let name = Data(source.path.utf8)
            guard name.count <= Int(UInt16.max) else { throw CompressionError.archive("A filename is too long for ZIP.") }
            let offset = try output.offset()
            let (time, date) = dosTimestamp(file.modifiedAt ?? Date())
            var header = Data()
            header.le(UInt32(0x04034b50)); header.le(UInt16(45)); header.le(UInt16(0x800))
            header.le(UInt16(8)); header.le(time); header.le(date); header.le(UInt32(0))
            header.le(UInt32.max); header.le(UInt32.max); header.le(UInt16(name.count)); header.le(UInt16(20))
            header.append(name); header.le(UInt16(1)); header.le(UInt16(16)); header.le(file.size); header.le(UInt64(0))
            try output.write(contentsOf: header)
            let dataOffset = try output.offset()
            var hash = SHA256()
            var checksum = crc32(0, nil, 0)
            var bytesRead: UInt64 = 0
            var stream = z_stream()
            guard deflateInit2_(&stream, quality.zipLevel, Z_DEFLATED, -MAX_WBITS, 8,
                                Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw CompressionError.archive("Could not initialize the ZIP encoder.")
            }
            do {
                defer { deflateEnd(&stream) }
                let input = file.isDirectory ? nil : try FileHandle(forReadingFrom: file.url)
                defer { try? input?.close() }
                while true {
                    try cancellation.check()
                    let chunk = try input?.read(upToCount: chunkSize) ?? Data()
                    let finish = chunk.isEmpty
                    if !finish {
                        bytesRead += UInt64(chunk.count)
                        hash.update(data: chunk)
                        checksum = chunk.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count)) }
                    }
                    try chunk.withUnsafeBytes { raw in
                        stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                        stream.avail_in = uInt(chunk.count)
                        repeat {
                            try cancellation.check()
                            var buffer = [UInt8](repeating: 0, count: chunkSize)
                            let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                                stream.next_out = pointer.baseAddress; stream.avail_out = uInt(chunkSize)
                                return deflate(&stream, finish ? Z_FINISH : Z_NO_FLUSH)
                            }
                            guard status == Z_OK || status == Z_STREAM_END else {
                                throw CompressionError.archive("ZIP encoding failed. Check the available disk space.")
                            }
                            let count = chunkSize - Int(stream.avail_out)
                            if count > 0 { try output.write(contentsOf: buffer.prefix(count)) }
                            if status == Z_STREAM_END { break }
                        } while stream.avail_in > 0 || stream.avail_out == 0 || finish
                    }
                    processed += UInt64(chunk.count)
                    let fraction = total > 0 ? Double(processed) / Double(total) : Double(index + 1) / Double(sources.count)
                    progress(.init(.compressing, fraction: fraction * 0.75, filename: file.name))
                    if finish { break }
                }
            }
            guard bytesRead == file.size else { throw CompressionError.fileChanged(file.name) }
            try file.checkUnchanged()
            let end = try output.offset()
            let compressedSize = end - dataOffset
            var crcData = Data(); crcData.le(UInt32(checksum))
            try output.seek(toOffset: offset + 14); try output.write(contentsOf: crcData)
            var sizes = Data(); sizes.le(file.size); sizes.le(compressedSize)
            try output.seek(toOffset: offset + 30 + UInt64(name.count) + 4); try output.write(contentsOf: sizes)
            try output.seek(toOffset: end)
            entries.append(Entry(name: name, offset: offset, dataOffset: dataOffset, size: file.size,
                                 compressedSize: compressedSize, crc: UInt32(checksum), digest: hash.finalize(), time: time, date: date, directory: file.isDirectory))
        }
        let directoryOffset = try output.offset()
        for entry in entries {
            try cancellation.check()
            var record = Data()
            record.le(UInt32(0x02014b50)); record.le(UInt16(0x032d)); record.le(UInt16(45)); record.le(UInt16(0x800))
            record.le(UInt16(8)); record.le(entry.time); record.le(entry.date); record.le(entry.crc)
            record.le(UInt32.max); record.le(UInt32.max); record.le(UInt16(entry.name.count)); record.le(UInt16(28))
            record.le(UInt16(0)); record.le(UInt16(0)); record.le(UInt16(0)); record.le(entry.directory ? UInt32(0o40755 << 16 | 0x10) : UInt32(0o100644 << 16)); record.le(UInt32.max)
            record.append(entry.name); record.le(UInt16(1)); record.le(UInt16(24))
            record.le(entry.size); record.le(entry.compressedSize); record.le(entry.offset)
            try output.write(contentsOf: record)
        }
        let directoryEnd = try output.offset()
        var footer = Data()
        footer.le(UInt32(0x06064b50)); footer.le(UInt64(44)); footer.le(UInt16(45)); footer.le(UInt16(45))
        footer.le(UInt32(0)); footer.le(UInt32(0)); footer.le(UInt64(entries.count)); footer.le(UInt64(entries.count))
        footer.le(directoryEnd - directoryOffset); footer.le(directoryOffset)
        footer.le(UInt32(0x07064b50)); footer.le(UInt32(0)); footer.le(directoryEnd); footer.le(UInt32(1))
        footer.le(UInt32(0x06054b50)); footer.le(UInt16(0)); footer.le(UInt16(0))
        footer.le(UInt16.max); footer.le(UInt16.max); footer.le(UInt32.max); footer.le(UInt32.max); footer.le(UInt16(0))
        try output.write(contentsOf: footer)
        try output.synchronize()
        try verify(url: url, entries: entries, total: total, cancellation: cancellation, progress: progress)
        try cancellation.check()
        let outputSize = try FileUtilities.size(of: url)
        keep = true
        return CompressionResult(url: url, workspace: workspace, originalSize: total,
                                 outputSize: outputSize, mode: .archive,
                                 detail: "Extract the ZIP to recover the original contents and included folder paths. Linked files outside the selected folder are not collected. Already compressed formats may not shrink.",
                                 verification: "Every file verified with SHA-256")
    }

    private func verify(url: URL, entries: [Entry], total: UInt64, cancellation: CancellationToken,
                        progress: ProgressHandler) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var verified: UInt64 = 0
        for (index, entry) in entries.enumerated() {
            try cancellation.check()
            try input.seek(toOffset: entry.dataOffset)
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw CompressionError.verification("Could not initialize archive verification.")
            }
            defer { inflateEnd(&stream) }
            var remaining = entry.compressedSize
            var hash = SHA256()
            var count: UInt64 = 0
            var ended = false
            while remaining > 0 && !ended {
                try cancellation.check()
                let chunk = try input.read(upToCount: min(chunkSize, Int(clamping: remaining))) ?? Data()
                guard !chunk.isEmpty else { throw CompressionError.verification("The archive is incomplete.") }
                remaining -= UInt64(chunk.count)
                try chunk.withUnsafeBytes { raw in
                    stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(chunk.count)
                    repeat {
                        try cancellation.check()
                        var buffer = [UInt8](repeating: 0, count: chunkSize)
                        let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                            stream.next_out = pointer.baseAddress; stream.avail_out = uInt(chunkSize)
                            return inflate(&stream, Z_NO_FLUSH)
                        }
                        guard status == Z_OK || status == Z_STREAM_END else {
                            throw CompressionError.verification("The archive did not pass decompression verification.")
                        }
                        let produced = chunkSize - Int(stream.avail_out)
                        if produced > 0 { hash.update(data: Data(buffer.prefix(produced))); count += UInt64(produced) }
                        if status == Z_STREAM_END { ended = true; break }
                    } while stream.avail_in > 0 || stream.avail_out == 0
                }
            }
            guard ended, remaining == 0, count == entry.size, hash.finalize() == entry.digest else {
                throw CompressionError.verification("The archive contents do not match the originals. The result was discarded.")
            }
            verified += count
            let fraction = total > 0 ? Double(verified) / Double(total) : Double(index + 1) / Double(entries.count)
            progress(.init(.verifying, fraction: 0.75 + fraction * 0.25, filename: String(decoding: entry.name, as: UTF8.self)))
        }
    }

    private func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(2107, max(1980, components.year ?? 1980))
        let time = ((components.hour ?? 0) << 11) | ((components.minute ?? 0) << 5) | ((components.second ?? 0) / 2)
        let day = ((year - 1980) << 9) | ((components.month ?? 1) << 5) | (components.day ?? 1)
        return (UInt16(time), UInt16(day))
    }
}

extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
