import Foundation

/// Finds fixable metadata problems in the local library. Pure functions over
/// lightweight snapshots — nothing here edits anything; the UI previews the
/// proposals and `LocalLibraryManager.applyMetadataEdits` applies the ones the
/// user keeps.
nonisolated enum MetadataDoctor {

    struct Item: Equatable {
        let id: UUID
        let title: String
        /// nil for the "This Device" placeholder / blank.
        let artist: String?
        let album: String?
        let hasArtwork: Bool
    }

    /// Several spellings that normalise to the same name.
    struct VariantGroup: Identifiable, Equatable {
        let key: String
        /// Spellings with how many tracks use each, most common first.
        let spellings: [(name: String, count: Int)]
        var id: String { key }

        var suggested: String { spellings.first?.name ?? "" }
        var trackCount: Int { spellings.reduce(0) { $0 + $1.count } }

        static func == (a: VariantGroup, b: VariantGroup) -> Bool {
            a.key == b.key && a.spellings.map { $0.name } == b.spellings.map { $0.name }
                && a.spellings.map { $0.count } == b.spellings.map { $0.count }
        }
    }

    struct TitleFix: Identifiable, Equatable {
        let id: UUID
        let old: String
        let new: String
        let reasons: [String]
    }

    struct ArtworkFix: Identifiable, Equatable {
        let id: UUID          // track that gets artwork
        let sourceID: UUID    // album-mate that has it
        let album: String
    }

    struct SplitFix: Identifiable, Equatable {
        let id: UUID
        let oldTitle: String
        let title: String
        let artist: String
        let album: String?
    }

    /// How a title packs extra fields, for tracks with no artist tag.
    enum SplitPattern: String, CaseIterable, Identifiable {
        case titleArtistAlbum
        case artistTitle
        case titleArtist

        var id: String { rawValue }

        var label: String {
            switch self {
            case .titleArtistAlbum: return "Title – Artist – Album"
            case .artistTitle: return "Artist – Title"
            case .titleArtist: return "Title – Artist"
            }
        }
    }

    // MARK: - Normalisation

    /// Case, accents, "&"/"and", a leading "The", spacing and punctuation
    /// are ignored: "A.R. Rahman", "AR Rahman" and "a r rahman" all match.
    static func key(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                          locale: Locale(identifier: "en_US_POSIX"))
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("the ") { t.removeFirst(4) }
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    // MARK: - Variants

    static func artistVariants(_ items: [Item]) -> [VariantGroup] {
        variants(items.compactMap(\.artist))
    }

    static func albumVariants(_ items: [Item]) -> [VariantGroup] {
        variants(items.compactMap(\.album))
    }

    static func variants(_ names: [String]) -> [VariantGroup] {
        var byKey: [String: [String: Int]] = [:]
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = key(name)
            guard !k.isEmpty else { continue }
            byKey[k, default: [:]][name, default: 0] += 1
        }
        return byKey.compactMap { k, spellings -> VariantGroup? in
            guard spellings.count > 1 else { return nil }
            let sorted = spellings.sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                // Tie: prefer the spelling with more capitals/punctuation
                // ("A.R. Rahman" over "ar rahman"), then alphabetical.
                let sa = styleScore(a.key), sb = styleScore(b.key)
                if sa != sb { return sa > sb }
                return a.key < b.key
            }
            return VariantGroup(key: k, spellings: sorted.map { ($0.key, $0.value) })
        }
        .sorted { $0.trackCount > $1.trackCount }
    }

    private static func styleScore(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { acc, c in
            acc + (CharacterSet.uppercaseLetters.contains(c) || CharacterSet.punctuationCharacters.contains(c) ? 1 : 0)
        }
    }

    // MARK: - Titles

    private static let junkWords = [
        "official video", "official music video", "official audio", "official lyric video",
        "official lyrical video", "lyric video", "lyrical video", "lyrics", "audio", "video song",
        "full video", "full song", "hd", "hq", "4k", "visualizer", "visualiser", "320kbps",
        "320 kbps", "128kbps", "mp3",
    ]

    static func tidyTitle(_ title: String) -> (String, [String]) {
        var t = title
        var reasons: [String] = []

        // "My_Song_Name" → "My Song Name" (only when there are no spaces).
        if !t.contains(" "), t.contains("_") {
            t = t.replacingOccurrences(of: "_", with: " ")
            reasons.append("underscores")
        }

        // Leading track number with a separator: "01 - Song", "03. Song", "7) Song".
        // A dash/underscore must be followed by a space, so "2-Step" stays.
        if let r = t.range(of: #"^\s*\d{1,3}\s*(?:[-–_]\s+|[.)]\s*(?=\p{L}))"#, options: .regularExpression) {
            let rest = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if rest.count >= 2, rest.rangeOfCharacter(from: .letters) != nil {
                t = rest
                reasons.append("track number")
            }
        }

        // Bracketed junk anywhere: "(Official Audio)", "[HD]", "(Lyrics)".
        let pattern = #"\s*[\(\[]\s*([^\)\]]+?)\s*[\)\]]"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = t as NSString
            var removed = false
            var result = t
            for match in regex.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let inner = ns.substring(with: match.range(at: 1)).lowercased()
                if junkWords.contains(inner) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: "")
                    removed = true
                }
            }
            if removed {
                t = result
                reasons.append("video/audio tag")
            }
        }

        // Spacing.
        let collapsed = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed != t {
            if reasons.isEmpty { reasons.append("spacing") }
            t = collapsed
        }

        return (t.isEmpty ? title : t, t.isEmpty ? [] : reasons)
    }

    static func titleFixes(_ items: [Item]) -> [TitleFix] {
        items.compactMap { item in
            let (new, reasons) = tidyTitle(item.title)
            guard new != item.title, !reasons.isEmpty else { return nil }
            return TitleFix(id: item.id, old: item.title, new: new, reasons: reasons)
        }
        .sorted { $0.old.localizedCaseInsensitiveCompare($1.old) == .orderedAscending }
    }

    // MARK: - Artwork

    /// Tracks without artwork whose album-mates have some (same album key;
    /// a mate with the same artist is preferred).
    static func artworkFixes(_ items: [Item]) -> [ArtworkFix] {
        let withArt = items.filter { $0.hasArtwork && $0.album != nil }
        var sources: [String: [Item]] = [:]
        for item in withArt { sources[key(item.album!), default: []].append(item) }
        return items.compactMap { item in
            guard !item.hasArtwork, let album = item.album else { return nil }
            let k = key(album)
            guard !k.isEmpty, let mates = sources[k], !mates.isEmpty else { return nil }
            let source = mates.first { m in
                m.artist.map(key) == item.artist.map(key)
            } ?? mates[0]
            return ArtworkFix(id: item.id, sourceID: source.id, album: album)
        }
    }

    // MARK: - Split from title

    static let separator = #"\s+[-–—]\s+"#

    /// Splits on " - ", " – " or " — " (spaces required, so "Jay-Z" stays whole).
    static func parts(_ title: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: separator) else { return [title] }
        let ns = title as NSString
        var pieces: [String] = []
        var last = 0
        for m in regex.matches(in: title, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        pieces.append(ns.substring(from: last))
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Proposals for tracks with no artist whose title holds the fields.
    static func splitFixes(_ items: [Item], pattern: SplitPattern) -> [SplitFix] {
        items.compactMap { item in
            guard item.artist == nil else { return nil }
            let p = parts(item.title)
            guard p.allSatisfy({ !$0.isEmpty }) else { return nil }
            switch pattern {
            case .titleArtistAlbum:
                guard p.count >= 3 else { return nil }
                // Anything past the third part belongs to the album name.
                return SplitFix(id: item.id, oldTitle: item.title, title: p[0], artist: p[1],
                                album: p[2...].joined(separator: " - "))
            case .artistTitle:
                guard p.count == 2 else { return nil }
                return SplitFix(id: item.id, oldTitle: item.title, title: p[1], artist: p[0], album: nil)
            case .titleArtist:
                guard p.count == 2 else { return nil }
                return SplitFix(id: item.id, oldTitle: item.title, title: p[0], artist: p[1], album: nil)
            }
        }
    }

    /// The pattern that matches the most artist-less tracks.
    static func likelyPattern(_ items: [Item]) -> SplitPattern {
        let artistless = items.filter { $0.artist == nil }
        let three = artistless.filter { parts($0.title).count >= 3 }.count
        let two = artistless.filter { parts($0.title).count == 2 }.count
        return three >= two ? .titleArtistAlbum : .artistTitle
    }
}
