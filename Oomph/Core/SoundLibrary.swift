import Foundation

/// A preset Oomph offers on top of eqtune's own, each for one everyday job. Picking one
/// imports it into eqtune under `id`, after which it's an ordinary preset to tweak.
struct LibraryPreset: Identifiable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case fix = "Fix Your Sound"
        case voice = "Voices"
        case music = "Music"
        case games = "Games"
    }

    let id: String
    let title: String
    let summary: String
    let symbol: String
    let category: Category
    let bands: [Band]

    /// The bands with a preamp that leaves room for their biggest boost, so the preset
    /// can't push loud audio into distortion.
    var preset: Preset {
        let peak = bands.peakGainDB(sampleRate: 48_000)
        return Preset(name: id, preampDB: peak > 0 ? -(peak * 10).rounded(.up) / 10 : 0, bands: bands)
    }
}

/// Tunings kept deliberately gentle (6 dB at most) so they improve most systems without
/// artifacts. Shelves use Q 0.71, the smoothest corner without a bump.
enum SoundLibrary {
    static func preset(_ id: String) -> LibraryPreset? { presets.first { $0.id == id } }

    static let presets: [LibraryPreset] = [
        LibraryPreset(id: "bass-boost", title: "Bass Boost",
                      summary: "Deeper, punchier low end for music and movies.",
                      symbol: "speaker.wave.3.fill", category: .fix,
                      bands: [low(105, 6), peak(300, -1.5, 1)]),
        LibraryPreset(id: "bass-reducer", title: "Bass Reducer",
                      summary: "Tames boomy speakers and bass-heavy headphones.",
                      symbol: "speaker.wave.1.fill", category: .fix,
                      bands: [low(150, -6)]),
        LibraryPreset(id: "treble-boost", title: "Treble Boost",
                      summary: "More detail and sparkle for dull or muffled sound.",
                      symbol: "sparkles", category: .fix,
                      bands: [high(6000, 5)]),
        LibraryPreset(id: "treble-reducer", title: "Treble Reducer",
                      summary: "Softens harsh, bright or tiring sound and sharp “s” sounds.",
                      symbol: "ear", category: .fix,
                      bands: [high(5000, -5), peak(7500, -2, 2)]),
        LibraryPreset(id: "laptop-speakers", title: "Laptop Speakers",
                      summary: "Fuller sound from built-in and small speakers, without straining them.",
                      symbol: "laptopcomputer", category: .fix,
                      // Small drivers can't move enough air below ~100 Hz: cut it and lift the
                      // upper bass they can play, so bass is heard instead of distorting.
                      bands: [low(70, -6), peak(180, 4, 1.1), peak(500, -1.5, 1), peak(3500, 1.5, 1), high(10000, 2.5)]),
        LibraryPreset(id: "loudness", title: "Loudness",
                      summary: "Fuller sound at low volume: brings back the bass and treble your ears miss when it’s quiet.",
                      symbol: "moon.stars", category: .fix,
                      bands: [low(100, 6), high(10000, 4)]),

        LibraryPreset(id: "vocal-clarity", title: "Vocal Clarity",
                      summary: "Brings singers forward and makes lyrics easier to follow.",
                      symbol: "music.mic", category: .voice,
                      bands: [low(100, -2), peak(300, -2, 1), peak(3000, 4, 1.2), high(10000, 1)]),
        LibraryPreset(id: "dialogue", title: "Dialogue",
                      summary: "Clear speech for movies, shows, podcasts and calls.",
                      symbol: "bubble.left.and.bubble.right", category: .voice,
                      bands: [low(150, -4), peak(300, -2, 1), peak(2500, 5, 0.9), peak(5000, 2, 1.4), high(12000, -2)]),

        LibraryPreset(id: "electronic", title: "Electronic",
                      summary: "Deep sub-bass and crisp highs for EDM and synth-heavy music.",
                      symbol: "waveform", category: .music,
                      bands: [low(80, 5), peak(400, -2, 0.8), high(9000, 3.5)]),
        LibraryPreset(id: "hip-hop", title: "Hip-Hop",
                      summary: "Heavy low end with punchy, present vocals.",
                      symbol: "hifispeaker.fill", category: .music,
                      bands: [peak(55, 5, 0.9), peak(120, 2, 1), peak(400, -2, 1), peak(3000, 2, 1), high(10000, 1.5)]),
        LibraryPreset(id: "rock", title: "Rock",
                      summary: "Punchy drums and guitars that cut through.",
                      symbol: "guitars", category: .music,
                      bands: [peak(90, 3, 1), peak(400, -2, 1), peak(2500, 2.5, 1), high(8000, 2)]),
        LibraryPreset(id: "acoustic", title: "Acoustic",
                      summary: "Natural warmth for acoustic, folk and singer-songwriter music.",
                      symbol: "music.note", category: .music,
                      bands: [peak(200, 2, 0.8), peak(600, -1, 1), peak(3000, 1.5, 1), high(10000, 2)]),
        LibraryPreset(id: "classical", title: "Classical & Jazz",
                      summary: "Open and natural, with extended highs for live instruments.",
                      symbol: "pianokeys", category: .music,
                      bands: [low(60, 2.5), peak(3000, -1, 1), high(12000, 2.5)]),

        LibraryPreset(id: "footsteps", title: "Footsteps",
                      summary: "Makes footsteps and positional cues easier to hear in games.",
                      symbol: "gamecontroller", category: .games,
                      bands: [low(150, -5), peak(2000, 3, 0.8), peak(4000, 4, 1), high(10000, 1)]),
    ]

    private static func peak(_ hz: Double, _ db: Double, _ q: Double) -> Band { Band(kind: .peaking, hz: hz, db: db, q: q) }
    private static func low(_ hz: Double, _ db: Double) -> Band { Band(kind: .lowShelf, hz: hz, db: db, q: 0.71) }
    private static func high(_ hz: Double, _ db: Double) -> Band { Band(kind: .highShelf, hz: hz, db: db, q: 0.71) }
}
