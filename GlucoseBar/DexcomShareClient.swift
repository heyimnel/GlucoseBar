//
//  DexcomShareClient.swift
//  GlucoseBar
//


import Foundation
import os.log

enum DexcomShareError: Error {
    case authenticationFailed
    case sessionFailed
    case sessionExpired
    case networkError
    case invalidResponse
    case noData
}

struct DexcomReading {
    let wallTime: Date
    let systemTime: Date
    let displayTime: Date
    let value: Int
    let trend: String

    var direction: String {
        switch trend {
        case "Flat": return "→"
        case "FortyFiveUp": return "↗"
        case "FortyFiveDown": return "↘"
        case "SingleUp": return "↑"
        case "SingleDown": return "↓"
        case "DoubleUp": return "↑"
        case "DoubleDown": return "↓"
        default: return "→"
        }
    }
}

class DexcomShareClient {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GlucoseBar", category: "DexcomShare")

    private var sessionId: String?
    private var accountId: String?

    func reset() {
        self.sessionId = nil
        self.accountId = nil
    }

    private let endpoints = [
        "us": "https://share2.dexcom.com/ShareWebServices/Services",
        "ous": "https://shareous1.dexcom.com/ShareWebServices/Services",
        "jp": "https://share.dexcom.jp/ShareWebServices/Services"
    ]

    private let appIds = [
        "us": "d89443d2-327c-4a6f-89e5-496bbb0317db",
        "ous": "d89443d2-327c-4a6f-89e5-496bbb0317db",
        "jp": "d8665ade-9673-4e27-9ff6-92db4ce13d13"
    ]

    func fetchLatestReading(username: String, password: String, region: String) async throws -> DexcomReading {
        let readings = try await fetchReadings(username: username, password: password, region: region, minutes: 10, maxCount: 1)
        guard let latest = readings.first else {
            throw DexcomShareError.noData
        }
        return latest
    }

    func fetchReadings(username: String, password: String, region: String, minutes: Int = 1440, maxCount: Int = 288) async throws -> [DexcomReading] {
        if let sessionId = sessionId {
            do {
                return try await getGlucoseData(sessionId: sessionId, region: region, minutes: minutes, maxCount: maxCount)
            } catch DexcomShareError.sessionExpired {
                logger.info("Session expired, re-authenticating")
                self.sessionId = nil
            }
        }

        if accountId == nil {
            accountId = try await getAccountId(username: username, password: password, region: region)
        }

        sessionId = try await getSessionId(accountId: accountId!, password: password, region: region)

        return try await getGlucoseData(sessionId: sessionId!, region: region, minutes: minutes, maxCount: maxCount)
    }

    private func getAccountId(username: String, password: String, region: String) async throws -> String {
        guard let baseUrl = endpoints[region] else {
            throw DexcomShareError.invalidResponse
        }

        let urlString = "\(baseUrl)/General/AuthenticatePublisherAccount"
        guard let url = URL(string: urlString) else {
            throw DexcomShareError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Dexcom Share/3.0.2.11 CFNetwork/711.2.23 Darwin/14.0.0", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "accountName": username,
            "password": password,
            "applicationId": appIds[region]!
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DexcomShareError.networkError
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Authentication failed with status: \(httpResponse.statusCode)")
            throw DexcomShareError.authenticationFailed
        }

        guard let accountId = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) else {
            throw DexcomShareError.invalidResponse
        }

        logger.info("Got account ID: \(accountId)")
        return accountId
    }

    private func getSessionId(accountId: String, password: String, region: String) async throws -> String {
        guard let baseUrl = endpoints[region] else {
            throw DexcomShareError.invalidResponse
        }

        let urlString = "\(baseUrl)/General/LoginPublisherAccountById"
        guard let url = URL(string: urlString) else {
            throw DexcomShareError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Dexcom Share/3.0.2.11 CFNetwork/711.2.23 Darwin/14.0.0", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "accountId": accountId,
            "password": password,
            "applicationId": appIds[region]!
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DexcomShareError.networkError
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Session creation failed with status: \(httpResponse.statusCode)")
            throw DexcomShareError.sessionFailed
        }

        guard let sessionId = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) else {
            throw DexcomShareError.invalidResponse
        }

        logger.info("Got session ID")
        return sessionId
    }

    private func getGlucoseData(sessionId: String, region: String, minutes: Int, maxCount: Int) async throws -> [DexcomReading] {
        guard let baseUrl = endpoints[region] else {
            throw DexcomShareError.invalidResponse
        }

        var components = URLComponents(string: "\(baseUrl)/Publisher/ReadPublisherLatestGlucoseValues")!
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "minutes", value: String(minutes)),
            URLQueryItem(name: "maxCount", value: String(maxCount))
        ]

        guard let url = components.url else {
            throw DexcomShareError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DexcomShareError.networkError
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw DexcomShareError.sessionExpired
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Glucose fetch failed with status: \(httpResponse.statusCode)")
            throw DexcomShareError.networkError
        }

        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DexcomShareError.invalidResponse
        }

        return try jsonArray.map { item in
            guard let wtString = item["WT"] as? String,
                  let stString = item["ST"] as? String,
                  let dtString = item["DT"] as? String,
                  let value = item["Value"] as? Int,
                  let trend = item["Trend"] as? String else {
                throw DexcomShareError.invalidResponse
            }

            let wt = try parseDate(wtString)
            let st = try parseDate(stString)
            let dt = try parseDate(dtString)

            return DexcomReading(
                wallTime: wt,
                systemTime: st,
                displayTime: dt,
                value: value,
                trend: trend
            )
        }
    }

    private func parseDate(_ dateString: String) throws -> Date {
        let pattern = "Date\\((\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: dateString, range: NSRange(dateString.startIndex..., in: dateString)),
              let timestampRange = Range(match.range(at: 1), in: dateString) else {
            throw DexcomShareError.invalidResponse
        }

        let timestampString = String(dateString[timestampRange])
        guard let timestamp = Double(timestampString) else {
            throw DexcomShareError.invalidResponse
        }

        return Date(timeIntervalSince1970: timestamp / 1000.0)
    }
}
