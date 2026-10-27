import AppKit

/// Detects the language of a stretch of text.
///
/// macOS's tagger has no Indonesian model and labels Indonesian text as Turkish, so
/// Indonesian is recognised first by its very frequent function words and verb affixes.
enum LanguageDetector {
    private static let tagger = NSLinguisticTagger(tagSchemes: [.language], options: 0)

    /// A BCP 47 code such as "id", "en" or "fr", or nil when the text is too short to tell.
    static func language(of text: String) -> String? {
        if Indonesian.looksIndonesian(text) { return "id" }
        tagger.string = text
        guard let detected = tagger.dominantLanguage, detected != "und" else { return nil }
        return detected
    }
}

/// Indonesian word lists and morphology shared by the grammar tagger and the spell checker.
enum Indonesian {
    static let pronouns: Set<String> = [
        "saya", "aku", "kamu", "engkau", "kau", "anda", "dia", "ia", "beliau", "kami", "kita",
        "mereka", "dikau", "daku", "kalian", "gue", "gua", "lu", "lo",
    ]
    static let prepositions: Set<String> = [
        "di", "ke", "dari", "pada", "kepada", "daripada", "untuk", "bagi", "dengan", "tentang",
        "oleh", "dalam", "sejak", "sampai", "hingga", "menuju", "terhadap", "antara", "tanpa",
        "atas", "demi", "per", "seperti", "sekitar", "melalui", "selama", "menurut",
    ]
    static let conjunctions: Set<String> = [
        "dan", "atau", "tetapi", "tapi", "namun", "karena", "sebab", "jika", "kalau", "apabila",
        "bahwa", "sehingga", "agar", "supaya", "ketika", "saat", "sewaktu", "walaupun", "meskipun",
        "lalu", "kemudian", "serta", "sedangkan", "padahal", "maka", "sebelum", "sesudah", "setelah",
        "bila", "jadi", "ataupun", "melainkan", "sambil", "seraya",
    ]
    static let adverbs: Set<String> = [
        "sangat", "sudah", "telah", "sedang", "lagi", "akan", "belum", "masih", "pernah", "tidak",
        "tak", "bukan", "juga", "hanya", "cuma", "selalu", "sering", "segera", "sekali", "terlalu",
        "paling", "lebih", "kurang", "agak", "cukup", "amat", "baru", "pun", "saja", "memang",
        "mungkin", "pasti", "tentu", "jarang", "kadang", "terus", "hampir", "bahkan", "benar-benar",
        "sungguh", "makin", "semakin", "dulu", "nanti", "kemarin", "besok", "sekarang", "tadi",
        "kini", "jangan", "harus", "bisa", "dapat", "boleh", "mau", "ingin", "perlu", "sempat",
    ]
    /// Determiners, numerals, question words and particles: grammatical glue that gets no color.
    static let functionWords: Set<String> = [
        "yang", "ini", "itu", "para", "sang", "si", "setiap", "tiap", "semua", "seluruh", "beberapa",
        "banyak", "sedikit", "suatu", "sebuah", "seorang", "seekor", "satu", "dua", "tiga", "empat",
        "lima", "apa", "siapa", "mengapa", "kenapa", "bagaimana", "kapan", "mana", "berapa", "adalah",
        "ialah", "merupakan", "yaitu", "yakni", "ya", "lah", "kah", "dong", "kok", "sih", "nah",
        "masing-masing", "segala", "tersebut",
    ]
    /// Common root verbs (no affix gives them away).
    static let rootVerbs: Set<String> = [
        "makan", "minum", "pergi", "datang", "tidur", "duduk", "pulang", "mandi", "tinggal", "masuk",
        "keluar", "naik", "turun", "lahir", "mati", "hidup", "bangun", "ingat", "lupa", "tahu", "suka",
        "cinta", "punya", "ada", "kerja", "pindah", "tiba", "kembali", "terbang", "jatuh", "lari",
        "diam", "pakai", "mulai", "selesai", "menang", "kalah", "tumbuh", "hilang", "main",
        "tunggu", "lihat", "dengar", "baca", "tulis", "beli", "jual", "bawa", "ambil", "kasih", "beri",
        "terima", "coba", "buat", "cari", "tanya", "jawab", "bicara", "pikir", "mengerti",
    ]
    static let adjectives: Set<String> = [
        "besar", "kecil", "baru", "lama", "baik", "buruk", "jelek", "bagus", "cantik", "indah",
        "panjang", "pendek", "tinggi", "rendah", "senang", "sedih", "marah", "takut", "segar", "deras",
        "mahal", "murah", "cepat", "lambat", "pelan", "panas", "dingin", "hangat", "kuat", "lemah",
        "sulit", "susah", "mudah", "gampang", "penting", "merah", "putih", "hitam", "hijau", "biru",
        "kuning", "cokelat", "ungu", "abu-abu", "muda", "tua", "kaya", "miskin", "pintar", "bodoh",
        "rajin", "malas", "ramah", "jauh", "dekat", "luas", "sempit", "berat", "ringan", "bersih",
        "kotor", "terang", "gelap", "enak", "lezat", "manis", "asin", "pahit", "pedas", "asam",
        "ramai", "sepi", "sehat", "sakit", "lelah", "capek", "lapar", "haus", "kenyang", "benar",
        "salah", "sama", "beda", "berbeda", "bahagia", "aneh", "lucu", "serius", "sibuk", "kosong",
        "penuh", "basah", "kering", "tebal", "tipis", "gemuk", "kurus", "tenang", "sopan", "jujur",
        "setia", "hebat", "keras", "lembut", "halus", "kasar", "nyaman", "aman", "bebas", "merdeka",
        "mental", "mentah", "menarik", "terkenal", "tertentu", "terbaik", "ternyata",
    ]
    /// Words that look like affixed verbs but are not.
    static let notVerbs: Set<String> = [
        "meja", "mereka", "merah", "merdeka", "mesin", "menteri", "menit", "media", "metode", "memang",
        "mental", "mentah", "menu", "meter", "medan", "mesjid", "masjid", "mendung", "melati",
        "dia", "diri", "dirinya", "dinding", "dingin", "dini", "dinas", "digital", "diskusi", "dimensi",
        "diet", "dilema", "direktur", "dinamis", "dimana", "disko", "dirut",
        "beras", "berat", "berita", "berlian", "bersih", "beruang", "berapa", "berkas", "beranda",
        "terang", "teras", "terus", "ternak", "teratai", "terlalu", "termasuk", "terutama", "tersebut",
        "ternyata", "terima", "terbaik", "tertentu", "terkenal", "terhadap", "terakhir",
    ]

    private static let markers: Set<String> = [
        "yang", "dan", "di", "ke", "dari", "ini", "itu", "dengan", "untuk", "tidak", "saya", "aku",
        "kamu", "dia", "kami", "kita", "mereka", "ada", "akan", "sudah", "telah", "pada", "kepada",
        "juga", "atau", "karena", "bahwa", "dalam", "oleh", "sangat", "bisa", "harus", "setiap",
        "sedang", "belum", "adalah", "tetapi", "namun", "seperti", "lebih", "para", "bagi", "hanya",
        "masih", "apa", "siapa", "bagaimana", "mengapa", "tak", "bukan", "ia", "kalau", "jika",
        "sebuah", "seorang", "agar", "supaya", "lagi", "saja", "pun", "sekali", "tersebut",
    ]

    /// True when the text reads as Indonesian (or Malay): many function words and verb affixes.
    static func looksIndonesian(_ text: String) -> Bool {
        let tokens = words(in: text).prefix(400).map { $0.lowercased() }
        guard tokens.count >= 3 else { return false }
        var score = 0
        for token in tokens {
            if markers.contains(token) {
                score += 2
            } else if token.hasSuffix("nya") || token.hasSuffix("kan") || hasVerbPrefix(token) {
                score += 1
            }
        }
        return Double(score) / Double(tokens.count) >= 0.45
    }

    /// Words (letters, with internal hyphens and apostrophes) and their ranges.
    static func wordRanges(in string: String, range: NSRange) -> [(String, NSRange)] {
        let ns = string as NSString
        var result: [(String, NSRange)] = []
        wordRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let r = match?.range else { return }
            result.append((ns.substring(with: r), r))
        }
        return result
    }

    static func words(in text: String) -> [String] {
        wordRanges(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map { $0.0 }
    }

    private static let wordRegex = try! NSRegularExpression(pattern: "\\p{L}+(?:['’-]\\p{L}+)*")

    /// me-/ber-/di-/ter-/memper- forms whose stem is long enough to be a real word.
    static func hasVerbPrefix(_ word: String) -> Bool {
        let w = word.lowercased()
        guard !notVerbs.contains(w) else { return false }
        for (prefix, minStem) in [("memper", 3), ("diper", 3), ("meng", 3), ("meny", 3), ("mem", 3),
                                  ("men", 3), ("me", 3), ("ber", 3), ("di", 4), ("ter", 3)] {
            guard w.hasPrefix(prefix) else { continue }
            let stem = w.dropFirst(prefix.count)
            guard stem.count >= minStem else { return false }
            // "me" alone only before l, r, w, y (melihat, merasa, mewarnai, meyakinkan).
            if prefix == "me", let first = stem.first, !"lrwy".contains(first) { return false }
            return true
        }
        return false
    }
}
