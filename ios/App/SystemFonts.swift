import UIKit
import CoreText
import CoreGraphics

/// Fonts the person installed on the iPad (Settings > General > Fonts, or font apps) are invisible
/// to apps. The only way an app can use them is Apple's own font picker: `addPicked` copies the
/// chosen family into Documents/Fonts (visible in Files), which VectorCraft scans when it starts.
enum SystemFonts {

    static var pickedFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Fonts", isDirectory: true)
    }

    // MARK: Fonts chosen in Apple's font picker

    /// Copies the chosen font, and the other styles of its family, into Documents/Fonts.
    /// Returns the font names that were stored.
    static func addPicked(_ descriptor: UIFontDescriptor) -> [String] {
        guard let folder = pickedFolder else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var descriptors: [CTFontDescriptor] = [descriptor as CTFontDescriptor]
        if let family = descriptor.object(forKey: .family) as? String {
            let query = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            if let all = CTFontDescriptorCreateMatchingFontDescriptors(query, nil) as? [CTFontDescriptor], !all.isEmpty {
                descriptors = all
            }
        }

        var stored: [String] = []
        for d in descriptors {
            let ct = CTFontCreateWithFontDescriptor(d, 12, nil)
            let postScript = CTFontCopyPostScriptName(ct) as String
            guard let fileName = fileName(for: postScript, font: ct) else { continue }
            if write(ct, to: folder.appendingPathComponent(fileName)) { stored.append(postScript) }
        }
        vcLog("added fonts from the picker: \(stored)")
        return stored
    }

    // MARK: Building font files

    private static func fileName(for postScript: String, font: CTFont) -> String? {
        let cg: CGFont = CTFontCopyGraphicsFont(font, nil)
        guard let tags = tableTags(of: cg) else { return nil }
        let isCFF = tags.contains(0x43464620) || tags.contains(0x43464632)   // 'CFF ' or 'CFF2'
        let safe = postScript.replacingOccurrences(of: "/", with: "_")
        return safe + (isCFF ? ".otf" : ".ttf")
    }

    private static func write(_ font: CTFont, to url: URL) -> Bool {
        let cg: CGFont = CTFontCopyGraphicsFont(font, nil)
        guard let tags = tableTags(of: cg) else { return false }
        let isCFF = tags.contains(0x43464620) || tags.contains(0x43464632)
        guard let data = sfnt(from: cg, tags: tags, isCFF: isCFF) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// The table tags of a font (like "head", "glyf", "CFF "), sorted.
    private static func tableTags(of font: CGFont) -> [UInt32]? {
        guard let raw = font.tableTags else { return nil }
        var tags: [UInt32] = []
        for i in 0..<CFArrayGetCount(raw) {
            tags.append(UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(raw, i))))
        }
        return tags.isEmpty ? nil : tags.sorted()
    }

    /// Builds a font file (TrueType or OpenType) out of the tables of a CoreGraphics font.
    private static func sfnt(from font: CGFont, tags: [UInt32], isCFF: Bool) -> Data? {
        var tables: [(tag: UInt32, data: Data)] = []
        for tag in tags {
            if let d = font.table(for: tag) { tables.append((tag, d as Data)) }
        }
        guard !tables.isEmpty else { return nil }

        let n = tables.count
        var power = 1
        var log = 0
        while power * 2 <= n { power *= 2; log += 1 }
        let searchRange = power * 16
        let rangeShift = n * 16 - searchRange

        var out = Data()
        func u32(_ v: UInt32) {
            out.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }
        func u16(_ v: Int) {
            out.append(contentsOf: [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }

        u32(isCFF ? 0x4F54544F : 0x00010000)   // 'OTTO' or TrueType
        u16(n); u16(searchRange); u16(log); u16(rangeShift)

        var offset = 12 + 16 * n
        var offsets: [Int] = []
        for t in tables {
            offsets.append(offset)
            offset += (t.data.count + 3) & ~3
        }
        for (i, t) in tables.enumerated() {
            u32(t.tag)
            u32(checksum(t.data))
            u32(UInt32(offsets[i]))
            u32(UInt32(t.data.count))
        }
        for t in tables {
            out.append(t.data)
            let pad = ((t.data.count + 3) & ~3) - t.data.count
            if pad > 0 { out.append(Data(count: pad)) }
        }
        return out
    }

    private static func checksum(_ data: Data) -> UInt32 {
        let bytes = [UInt8](data)
        var sum: UInt32 = 0
        var i = 0
        while i < bytes.count {
            var word: UInt32 = 0
            for k in 0..<4 {
                word = (word << 8) | (i + k < bytes.count ? UInt32(bytes[i + k]) : 0)
            }
            sum = sum &+ word
            i += 4
        }
        return sum
    }
}
