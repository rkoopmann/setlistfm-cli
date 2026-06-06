//
//  main.swift
//  setlist.fm
//
//  Created by Richard Koopmann on 4/14/24.
//
//  A command-line tool that fetches every concert a setlist.fm user has
//  marked as "attended", then writes a summary `list.json` plus one JSON
//  file per event. Ported from https://github.com/rkoopmann/setlist.fm.go
//

import Foundation

// MARK: - API response models
// Property names match the setlist.fm JSON keys, so no CodingKeys are needed
// except where a Swift name would differ from the wire format.

struct ArtistObject: Codable {
    var mbid: String
    var tmid: Int?
    var name: String
    var sortName: String
    var disambiguation: String
    var url: String
}

struct CoordsObject: Codable {
    var lat: Double
    var long: Double
}

struct CountryObject: Codable {
    var code: String
    var name: String
}

struct CityObject: Codable {
    var id: String
    var name: String
    var state: String
    var stateCode: String
    var coords: CoordsObject
    var country: CountryObject
}

struct VenueObject: Codable {
    var id: String
    var name: String
    var city: CityObject
    var url: String
}

struct TourObject: Codable {
    var name: String
}

struct SongObject: Codable {
    var name: String
    var with: ArtistObject?
    var cover: ArtistObject?
    var info: String?
    var tape: Bool?

    enum CodingKeys: String, CodingKey {
        case name, with, info, tape
        case cover = "artist" // setlist.fm calls the covered artist "artist"
    }
}

struct SetObject: Codable {
    var name: String?
    var encore: Int?
    var song: [SongObject]
}

struct SetsList: Codable {
    var set: [SetObject]
}

struct SetlistObject: Codable {
    var id: String
    var versionId: String
    var eventDate: String
    var lastUpdated: String
    var artist: ArtistObject
    var venue: VenueObject
    var tour: TourObject?
    var sets: SetsList
    var info: String?
    var url: String
}

struct ResponseSetlist: Codable {
    var type: String
    var itemsPerPage: Int
    var page: Int
    var total: Int
    var setlist: [SetlistObject]
}

// MARK: - Output models
// These mirror the Go `EventObject`/`EventsList`, so list.json keeps the same
// capitalized keys the Go tool produced.

struct EventObject: Codable {
    var Id: String
    var Date: String
    var Venue: String
    var City: String
    var State: String
    var Artist: String
    var Tour: String
    var SongsPlayed: Int
    var Lat: Double
    var Long: Double
    var Link: String
}

struct EventsList: Codable {
    var Event: [EventObject] = []
}

// MARK: - Configuration

struct Configuration: Codable {
    var user: String
    var apiKey: String
    var outputPath: String
}

// MARK: - Helpers

/// Log a message to standard error (mirrors Go's `log` package).
func logErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Lowercase, slugify, and strip punctuation for filename use.
func cleanString(_ input: String) -> String {
    var s = input.lowercased()
    s = s.replacingOccurrences(of: " ", with: "-")
    s = s.replacingOccurrences(of: "'", with: "")
    s = s.replacingOccurrences(of: "&", with: "+")
    s = s.replacingOccurrences(of: "\u{2018}", with: "") // ‘
    s = s.replacingOccurrences(of: "\u{2019}", with: "") // ’
    s = s.replacingOccurrences(of: "\"", with: "")
    return s
}

private let inputDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "dd-MM-yyyy" // setlist.fm eventDate format
    return f
}()

private let outputDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

/// Convert a setlist.fm "dd-MM-yyyy" date string into "yyyy-MM-dd".
func normalizedDate(_ raw: String) -> String {
    guard let date = inputDateFormatter.date(from: raw) else { return raw }
    return outputDateFormatter.string(from: date)
}

// MARK: - Networking

enum SetlistError: Error {
    case badStatus(Int)
}

/// Fetch a single page of attended events for a user.
func fetchAttendedPage(user: String, apiKey: String, page: Int) async throws -> ResponseSetlist {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "api.setlist.fm"
    components.path = "/rest/1.0/user/\(user)/attended"
    components.queryItems = [URLQueryItem(name: "p", value: String(page))]

    var request = URLRequest(url: components.url!)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw SetlistError.badStatus(http.statusCode)
    }
    return try JSONDecoder().decode(ResponseSetlist.self, from: data)
}

/// Fetch every page of attended events, concatenating the setlists.
func getEventsAttendedByUser(user: String, apiKey: String) async throws -> ResponseSetlist {
    var main = try await fetchAttendedPage(user: user, apiKey: apiKey, page: 1)

    let pages = main.itemsPerPage > 0
        ? (main.total + main.itemsPerPage - 1) / main.itemsPerPage // ceil division
        : 1
    logErr("attended - page 1 of \(pages)")

    if pages >= 2 {
        for page in 2...pages {
            logErr("attended - page \(page) of \(pages)")
            let next = try await fetchAttendedPage(user: user, apiKey: apiKey, page: page)
            main.setlist.append(contentsOf: next.setlist)
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms, be kind to the API
        }
    }
    return main
}

// MARK: - Output writers

let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
}()

/// Write the summary `list.json`.
func writeEventsList(_ events: ResponseSetlist, path: String) throws {
    var list = EventsList()
    for event in events.setlist {
        let songsPlayed = event.sets.set.reduce(0) { $0 + $1.song.count }
        list.Event.append(EventObject(
            Id: event.id,
            Date: normalizedDate(event.eventDate),
            Venue: event.venue.name,
            City: event.venue.city.name,
            State: event.venue.city.state,
            Artist: event.artist.name,
            Tour: event.tour?.name ?? "",
            SongsPlayed: songsPlayed,
            Lat: event.venue.city.coords.lat,
            Long: event.venue.city.coords.long,
            Link: event.url
        ))
    }

    let fileOut = path + "list.json"
    let data = try jsonEncoder.encode(list)
    try data.write(to: URL(fileURLWithPath: fileOut))
}

/// Write one `<date>-<artist>.json` file per event.
func writeEventFiles(_ events: ResponseSetlist, path: String) throws {
    for event in events.setlist {
        let fileOut = path + normalizedDate(event.eventDate) + "-" + cleanString(event.artist.name) + ".json"
        let data = try jsonEncoder.encode(event)
        try data.write(to: URL(fileURLWithPath: fileOut))
    }
}

// MARK: - Entry point

func loadConfiguration() throws -> Configuration {
    let data = try Data(contentsOf: URL(fileURLWithPath: "configuration.json"))
    return try JSONDecoder().decode(Configuration.self, from: data)
}

do {
    let configuration = try loadConfiguration()
    let events = try await getEventsAttendedByUser(user: configuration.user, apiKey: configuration.apiKey)
    logErr("fetched \(events.setlist.count) attended events")
    try writeEventsList(events, path: configuration.outputPath)
    try writeEventFiles(events, path: configuration.outputPath)
    logErr("done — wrote list.json and \(events.setlist.count) event files to \(configuration.outputPath)")
} catch {
    logErr("error: \(error)")
    exit(1)
}
