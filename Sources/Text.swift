// Normalising message text so the bagel rules can't be dodged with lookalike letters, spacing,
// leetspeak or another language. Everything here is pure and covered by `--text-test`.

import Foundation

enum Text {
    /// Latin lookalikes from other scripts, folded to the letter they imitate. Only the letters that
    /// appear in "bagel"/"legab" need entries, but a wider set is cheap and future-proof.
    private static let confusables: [Character: Character] = [
        // a
        "\u{0430}": "a", "\u{03B1}": "a", "\u{0251}": "a", "\u{04D1}": "a",
        // b
        "\u{0184}": "b", "\u{042C}": "b", "\u{044C}": "b", "\u{0432}": "b", "\u{0183}": "b",
        // e
        "\u{0435}": "e", "\u{03B5}": "e", "\u{0454}": "e", "\u{04BD}": "e", "\u{212E}": "e",
        // g
        "\u{0261}": "g", "\u{050D}": "g", "\u{0581}": "g",
        // l
        "\u{217C}": "l", "\u{2113}": "l", "\u{0406}": "l", "\u{04C0}": "l", "\u{01C0}": "l",
        // o (handy for other words)
        "\u{043E}": "o", "\u{03BF}": "o", "\u{0585}": "o",
        // s
        "\u{0455}": "s", "\u{10BD}": "s",
    ]

    /// Digits and symbols used as letters.
    private static let leet: [Character: Character] = [
        "4": "a", "@": "a", "8": "b", "3": "e", "€": "e", "1": "l", "|": "l", "!": "l",
        "0": "o", "5": "s", "$": "s", "7": "t", "9": "g", "6": "g",
    ]

    /// Characters that carry no meaning here and are only used to break up a word: zero-width joiners,
    /// variation selectors, soft hyphens, bidi controls and the object-replacement placeholder.
    private static func isNoise(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0xFE00...0xFE0F, 0xFEFF, 0xFFFC:
            return true
        default:
            return scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    /// Compatibility-folded, lowercased, with lookalikes mapped to Latin and noise removed. Keeps
    /// spaces and punctuation, so word-boundary regexes still work.
    static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        var out = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where !isNoise(scalar) {
            out.append(contentsOf: String(confusables[Character(scalar)] ?? Character(scalar)).unicodeScalars)
        }
        return String(out)
    }

    /// `normalized`, then everything that isn't a letter or digit stripped and leet folded, so
    /// "b a g e l", "b.a.g.e.l", "b4g3l" collapse to one run. Shown in `--text-test` for debugging.
    static func squashed(_ text: String) -> String {
        String(normalized(text).compactMap { ch -> Character? in
            if ch.isLetter || ch.isNumber { return leet[ch] ?? ch }
            return nil
        })
    }

    /// Matches "bagel" (or "legab") spaced out, punctuated or leetspoken, but anchored so it can't
    /// straddle word boundaries — "cabbage leaves" squashed contains "bagel", this doesn't match it.
    /// Run on `normalized` text, so homoglyphs and fullwidth forms are already folded.
    private static let obfuscated: NSRegularExpression = {
        let sep = "[\\s._*·•+-]{0,2}"
        let b = "[b8]", a = "[a4@]", g = "[g9]", e = "[e3]", l = "[l1|!]"
        let forward = [b, a, g, e, l].joined(separator: sep)
        let reverse = [l, e, g, a, b].joined(separator: sep)
        let pattern = "(?<![a-z0-9])(?:\(forward)|\(reverse))(?![a-z0-9])"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// "bagel" written out in other languages, matched literally against the normalized text. Not
    /// exhaustive, just the common ones a colleague might reach for.
    static let foreignBagel = [
        "\u{30D9}\u{30FC}\u{30B0}\u{30EB}",  // ベーグル (ja)
        "\u{8D1D}\u{679C}", "\u{8C9D}\u{679C}",  // 贝果 / 貝果 (zh)
        "\u{BCA0}\u{C774}\u{AE00}",  // 베이글 (ko)
        "\u{0431}\u{0435}\u{0439}\u{0433}\u{043B}", "\u{0431}\u{0443}\u{0431}\u{043B}\u{0438}\u{043A}",  // бейгл / бублик (ru)
        "\u{05D1}\u{05D9}\u{05D9}\u{05D2}\u{05DC}",  // בייגל (he)
        "beigel", "beygel", "beygl",  // yiddish/transliterations
    ]

    /// Whether the text names a bagel in a way the plain regexes would miss (spaced out, leetspoken,
    /// disguised with lookalikes, or in another language). Returns the form found, for the log.
    static func hiddenBagel(in text: String) -> String? {
        let normal = normalized(text)
        let range = NSRange(normal.startIndex..., in: normal)
        if let m = obfuscated.firstMatch(in: normal, range: range), let r = Range(m.range, in: normal) {
            return "\"\(normal[r])\" (disguised)"
        }
        for word in foreignBagel where normal.contains(word.lowercased()) {
            return "\"\(word)\""
        }
        return nil
    }
}
