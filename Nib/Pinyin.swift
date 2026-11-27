import Foundation

/// Pinyin matching for Quick Open: "zhongwen", "zw" or "zhongw" find "中文笔记.md".
/// A Chinese character matches its full syllable, its first letter, or (at the end of the query word only) a prefix of its syllable.
/// Matching is a contiguous run of characters, like a substring match. Foundation only, so it can be tested without the app.
enum Pinyin {
    nonisolated(unsafe) private static var cache: [Character: String] = [:]
    private static let lock = NSLock()

    /// Toneless lowercase syllable of a Han character, or nil for anything else.
    static func syllable(_ ch: Character) -> String? {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, isHan(scalar) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[ch] { return hit }
        let latin = String(ch).applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?.lowercased()
            .filter { $0 >= "a" && $0 <= "z" } ?? ""
        cache[ch] = latin
        return latin.isEmpty ? nil : latin
    }

    private static func isHan(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0x20000...0x2A6DF).contains(s.value)
    }

    /// Whether the query word (lowercase ASCII letters and digits) matches a contiguous run of the text.
    /// False at once when the word is not ASCII or the text has no Han characters.
    static func matches(_ word: String, in text: String) -> Bool {
        let query = Array(word.utf8)
        guard !query.isEmpty, query.allSatisfy({ $0 < 128 }), !text.utf8.allSatisfy({ $0 < 128 }) else { return false }
        let chars = Array(text.lowercased())
        let syllables = chars.map(syllable)
        guard syllables.contains(where: { $0 != nil }) else { return false }
        for start in chars.indices where match(query, 0, chars, syllables, start) { return true }
        return false
    }

    private static func match(_ q: [UInt8], _ qi: Int, _ chars: [Character], _ syl: [String?], _ ci: Int) -> Bool {
        if qi == q.count { return true }
        guard ci < chars.count else { return false }
        if let s = syl[ci] {
            let sb = Array(s.utf8)
            let rest = q.count - qi
            // Query ends inside this syllable: "zhongw" matches 中文.
            if rest <= sb.count, Array(q[qi...]) == Array(sb[..<rest]) { return true }
            // Full syllable.
            if rest > sb.count, Array(q[qi..<(qi + sb.count)]) == sb, match(q, qi + sb.count, chars, syl, ci + 1) { return true }
            // First letter.
            if q[qi] == sb[0], match(q, qi + 1, chars, syl, ci + 1) { return true }
            return false
        }
        guard let ascii = chars[ci].asciiValue, ascii == q[qi] else { return false }
        return match(q, qi + 1, chars, syl, ci + 1)
    }
}
