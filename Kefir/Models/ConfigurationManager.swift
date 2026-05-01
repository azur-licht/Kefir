import Foundation
import SwiftKEF

// MARK: - Data Models

struct SpeakerProfile: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let host: String
    let lastSeen: Date
    let isDefault: Bool
    /// If set, the app will switch the speaker to this source automatically
    /// every time the user powers it on from standby. Lets users land on a
    /// useful default (e.g. "Optical" for a TV setup) instead of whatever
    /// source the speaker last used. `nil` keeps the speaker's own choice.
    let preferredSourceOnWake: KEFSource?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        lastSeen: Date = Date(),
        isDefault: Bool = false,
        preferredSourceOnWake: KEFSource? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.lastSeen = lastSeen
        self.isDefault = isDefault
        self.preferredSourceOnWake = preferredSourceOnWake
    }

    // Custom Codable so we don't have to require `KEFSource: Codable`
    // upstream — we just persist the raw string. Older configs that don't
    // have `preferredSourceOnWake` decode cleanly (the field is optional).
    private enum CodingKeys: String, CodingKey {
        case id, name, host, lastSeen, isDefault, preferredSourceOnWake
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        isDefault = try c.decode(Bool.self, forKey: .isDefault)
        if let raw = try c.decodeIfPresent(String.self, forKey: .preferredSourceOnWake) {
            preferredSourceOnWake = KEFSource(rawValue: raw)
        } else {
            preferredSourceOnWake = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(lastSeen, forKey: .lastSeen)
        try c.encode(isDefault, forKey: .isDefault)
        try c.encodeIfPresent(preferredSourceOnWake?.rawValue, forKey: .preferredSourceOnWake)
    }
}

struct Configuration: Codable {
    var speakers: [SpeakerProfile]
    var theme: Theme
    
    init(speakers: [SpeakerProfile] = [], theme: Theme = Theme()) {
        self.speakers = speakers
        self.theme = theme
    }
}

struct Theme: Codable {
    let useColors: Bool
    let useEmojis: Bool
    
    init(useColors: Bool = true, useEmojis: Bool = true) {
        self.useColors = useColors
        self.useEmojis = useEmojis
    }
}

// MARK: - Configuration Manager

actor ConfigurationManager {
    private let configDirectory: URL
    private let configFile: URL
    private var configuration: Configuration
    
    init() {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.configDirectory = homeDirectory.appendingPathComponent(".config/kefir")
        self.configFile = configDirectory.appendingPathComponent("config.json")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        
        // Load or create configuration
        if FileManager.default.fileExists(atPath: configFile.path),
           let data = try? Data(contentsOf: configFile) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let config = try? decoder.decode(Configuration.self, from: data) {
                self.configuration = config
            } else {
                self.configuration = Configuration()
            }
        } else {
            self.configuration = Configuration()
        }
    }
    
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(configuration)
        try data.write(to: configFile)
    }
    
    // MARK: - Speaker Management
    
    func getSpeakers() -> [SpeakerProfile] {
        return configuration.speakers
    }
    
    func getSpeaker(byName name: String) -> SpeakerProfile? {
        return configuration.speakers.first { $0.name.lowercased() == name.lowercased() }
    }
    
    func getSpeaker(byId id: UUID) -> SpeakerProfile? {
        return configuration.speakers.first { $0.id == id }
    }
    
    func getDefaultSpeaker() -> SpeakerProfile? {
        return configuration.speakers.first { $0.isDefault }
    }
    
    @discardableResult
    func addSpeaker(name: String, host: String, setAsDefault: Bool = false) throws -> SpeakerProfile {
        // Check if speaker with same name exists
        if configuration.speakers.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            throw ConfigurationError.speakerAlreadyExists(name: name)
        }
        
        // If setting as default, clear other defaults
        if setAsDefault {
            configuration.speakers = configuration.speakers.map { speaker in
                SpeakerProfile(
                    id: speaker.id,
                    name: speaker.name,
                    host: speaker.host,
                    lastSeen: speaker.lastSeen,
                    isDefault: false,
                    preferredSourceOnWake: speaker.preferredSourceOnWake
                )
            }
        }
        
        let newSpeaker = SpeakerProfile(
            name: name,
            host: host,
            isDefault: setAsDefault || configuration.speakers.isEmpty
        )
        
        configuration.speakers.append(newSpeaker)
        try save()
        
        return newSpeaker
    }
    
    func updateSpeaker(id: UUID, name: String? = nil, host: String? = nil) throws {
        guard let index = configuration.speakers.firstIndex(where: { $0.id == id }) else {
            throw ConfigurationError.speakerNotFound
        }

        let speaker = configuration.speakers[index]
        configuration.speakers[index] = SpeakerProfile(
            id: speaker.id,
            name: name ?? speaker.name,
            host: host ?? speaker.host,
            lastSeen: Date(),
            isDefault: speaker.isDefault,
            preferredSourceOnWake: speaker.preferredSourceOnWake
        )

        try save()
    }

    /// Sets (or clears, when `source` is `nil`) the source the app should
    /// switch to right after powering this speaker on from standby.
    func setPreferredSourceOnWake(id: UUID, source: KEFSource?) throws {
        guard let index = configuration.speakers.firstIndex(where: { $0.id == id }) else {
            throw ConfigurationError.speakerNotFound
        }

        let speaker = configuration.speakers[index]
        configuration.speakers[index] = SpeakerProfile(
            id: speaker.id,
            name: speaker.name,
            host: speaker.host,
            lastSeen: speaker.lastSeen,
            isDefault: speaker.isDefault,
            preferredSourceOnWake: source
        )

        try save()
    }
    
    func removeSpeaker(id: UUID) throws {
        guard let index = configuration.speakers.firstIndex(where: { $0.id == id }) else {
            throw ConfigurationError.speakerNotFound
        }
        
        let wasDefault = configuration.speakers[index].isDefault
        configuration.speakers.remove(at: index)
        
        // If removed speaker was default, set first speaker as default
        if wasDefault && !configuration.speakers.isEmpty {
            configuration.speakers[0] = SpeakerProfile(
                id: configuration.speakers[0].id,
                name: configuration.speakers[0].name,
                host: configuration.speakers[0].host,
                lastSeen: configuration.speakers[0].lastSeen,
                isDefault: true,
                preferredSourceOnWake: configuration.speakers[0].preferredSourceOnWake
            )
        }
        
        try save()
    }
    
    func setDefaultSpeaker(id: UUID) throws {
        guard configuration.speakers.contains(where: { $0.id == id }) else {
            throw ConfigurationError.speakerNotFound
        }
        
        configuration.speakers = configuration.speakers.map { speaker in
            SpeakerProfile(
                id: speaker.id,
                name: speaker.name,
                host: speaker.host,
                lastSeen: speaker.lastSeen,
                isDefault: speaker.id == id,
                preferredSourceOnWake: speaker.preferredSourceOnWake
            )
        }

        try save()
    }

    func updateLastUsed(speakerId: UUID) throws {
        guard let index = configuration.speakers.firstIndex(where: { $0.id == speakerId }) else {
            throw ConfigurationError.speakerNotFound
        }

        let speaker = configuration.speakers[index]
        configuration.speakers[index] = SpeakerProfile(
            id: speaker.id,
            name: speaker.name,
            host: speaker.host,
            lastSeen: Date(),
            isDefault: speaker.isDefault,
            preferredSourceOnWake: speaker.preferredSourceOnWake
        )

        try save()
    }
    
    // MARK: - Theme Management
    
    func getTheme() -> Theme {
        return configuration.theme
    }
    
    func updateTheme(useColors: Bool? = nil, useEmojis: Bool? = nil) throws {
        configuration.theme = Theme(
            useColors: useColors ?? configuration.theme.useColors,
            useEmojis: useEmojis ?? configuration.theme.useEmojis
        )
        
        try save()
    }
}

// MARK: - Errors

enum ConfigurationError: LocalizedError {
    case speakerNotFound
    case speakerAlreadyExists(name: String)
    
    var errorDescription: String? {
        switch self {
        case .speakerNotFound:
            return NSLocalizedString("Speaker not found in configuration", comment: "Error when speaker is not found")
        case .speakerAlreadyExists(let name):
            return String(format: NSLocalizedString("A speaker named '%@' already exists", comment: "Error when speaker name already exists"), name)
        }
    }
}