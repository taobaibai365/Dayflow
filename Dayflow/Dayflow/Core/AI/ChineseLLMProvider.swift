//
//  ChineseLLMProvider.swift
//  Dayflow
//
//  Support for Chinese AI providers: DeepSeek, Zhipu (GLM), Alibaba Qwen
//

import Foundation
import AppKit

final class ChineseLLMProvider: LLMProvider {
    private let providerType: ChineseLLMProviderType
    private let apiKey: String
    private let endpoint: String
    private let model: String
    private let screenshotInterval: TimeInterval = 10  // seconds between screenshots

    // MARK: - API Models (nested to avoid conflicts)

    private struct APIChatRequest: Codable {
        let model: String
        let messages: [APIChatMessage]
    }

    private struct APIChatMessage: Codable {
        let role: String
        let content: APIMessageContentOrString
    }

    private enum APIMessageContentOrString: Codable {
        case string(String)
        case contentArray([APIMessageContent])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s):
                try container.encode(s)
            case .contentArray(let arr):
                try container.encode(arr)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                self = .string(s)
            } else if let arr = try? container.decode([APIMessageContent].self) {
                self = .contentArray(arr)
            } else {
                throw DecodingError.typeMismatch(APIMessageContentOrString.self, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Expected String or [APIMessageContent]"))
            }
        }
    }

    private struct APIMessageContent: Codable {
        let type: String
        let text: String?
        let image_url: APIImageURL?

        struct APIImageURL: Codable {
            let url: String
        }
    }

    private struct APIChatResponse: Codable {
        let choices: [APIChoice]
        let usage: [APIUsage]?

        struct APIChoice: Codable {
            let message: APIMessage
            let finish_reason: String?
        }

        struct APIMessage: Codable {
            let content: String
            let role: String
        }

        struct APIUsage: Codable {
            let prompt_tokens: Int
            let completion_tokens: Int
            let total_tokens: Int
        }
    }

    init(providerType: ChineseLLMProviderType, apiKey: String, endpoint: String? = nil, model: String? = nil) {
        self.providerType = providerType
        self.apiKey = apiKey
        self.endpoint = endpoint ?? providerType.defaultEndpoint
        self.model = model ?? providerType.defaultModel
    }

    // MARK: - LLMProvider Protocol

    func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?) async throws -> (observations: [Observation], log: LLMCall) {
        guard !screenshots.isEmpty else {
            throw NSError(domain: "ChineseLLMProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
        }

        let callStart = Date()
        let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }

        // Sample ~15 evenly spaced screenshots to avoid overloading the API
        let targetSamples = 15
        let strideAmount = max(1, sortedScreenshots.count / targetSamples)
        let sampledScreenshots = Swift.stride(from: 0, to: sortedScreenshots.count, by: strideAmount).map { sortedScreenshots[$0] }

        // Calculate duration from timestamp range
        let firstTs = sampledScreenshots.first!.capturedAt
        let lastTs = sampledScreenshots.last!.capturedAt
        let durationSeconds = TimeInterval(lastTs - firstTs)

        // Describe each screenshot
        var frameDescriptions: [(timestamp: TimeInterval, description: String)] = []

        for screenshot in sampledScreenshots {
            guard let frameData = loadScreenshotAsFrameData(screenshot, relativeTo: firstTs) else {
                print("[\(providerType.displayName)] ⚠️ Failed to load screenshot: \(screenshot.filePath)")
                continue
            }

            if let description = await getFrameDescription(frameData, batchId: batchId) {
                frameDescriptions.append((timestamp: frameData.timestamp, description: description))
            }
        }

        guard !frameDescriptions.isEmpty else {
            throw NSError(
                domain: "ChineseLLMProvider",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Failed to describe any screenshots. Please check your API key and network connection."]
            )
        }

        // Merge frame descriptions into coherent observations
        let observations = try await mergeFrameDescriptions(
            frameDescriptions,
            batchStartTime: batchStartTime,
            videoDuration: durationSeconds,
            batchId: batchId
        )

        let totalTime = Date().timeIntervalSince(callStart)
        let log = LLMCall(
            timestamp: callStart,
            latency: totalTime,
            input: "Screenshot transcription: \(screenshots.count) screenshots → \(observations.count) observations",
            output: "Processed \(screenshots.count) screenshots in \(String(format: "%.2f", totalTime))s"
        )

        return (observations, log)
    }

    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], log: LLMCall) {
        let callStart = Date()
        var logs: [String] = []

        let sortedObservations = context.batchObservations.sorted { $0.startTs < $1.startTs }

        guard let firstObservation = sortedObservations.first,
              let lastObservation = sortedObservations.last else {
            throw NSError(
                domain: "ChineseLLMProvider",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "Cannot generate activity cards: no observations provided"]
            )
        }

        // Generate initial activity card for these observations
        let titleSummary = try await generateTitleAndSummary(
            observations: sortedObservations,
            categories: context.categories,
            batchId: batchId
        )

        logs.append("Generated title: \(titleSummary.0)")

        let normalizedCategory = normalizeCategory(titleSummary.2, categories: context.categories)

        let initialCard = ActivityCardData(
            startTime: formatTimestampForPrompt(firstObservation.startTs),
            endTime: formatTimestampForPrompt(lastObservation.endTs),
            category: normalizedCategory,
            subcategory: "",
            title: titleSummary.0,
            summary: titleSummary.1,
            detailedSummary: "",
            distractions: nil,
            appSites: nil
        )

        var allCards = context.existingCards

        // For simplicity, just append the new card
        allCards.append(initialCard)

        let totalLatency = Date().timeIntervalSince(callStart)

        let combinedLog = LLMCall(
            timestamp: callStart,
            latency: totalLatency,
            input: "Activity card generation",
            output: logs.joined(separator: "\n\n---\n\n")
        )

        return (allCards, combinedLog)
    }

    func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
        let callStart = Date()

        let request = APIChatRequest(
            model: model,
            messages: [
                APIChatMessage(role: "user", content: .string(prompt))
            ]
        )

        let response = try await callChatAPI(request, operation: "generate_text", maxRetries: 3)
        let text = response.choices.first?.message.content ?? ""

        let latency = Date().timeIntervalSince(callStart)
        let log = LLMCall(
            timestamp: callStart,
            latency: latency,
            input: prompt,
            output: text
        )

        return (text, log)
    }

    func generateTextStreaming(prompt: String) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (text, _) = try await self.generateText(prompt: prompt)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Helpers

    private struct FrameData {
        let image: Data  // base64 encoded image data
        let timestamp: TimeInterval
    }

    private func loadScreenshotAsFrameData(_ screenshot: Screenshot, relativeTo baseTimestamp: Int) -> FrameData? {
        let url = URL(fileURLWithPath: screenshot.filePath)

        guard let imageData = try? Data(contentsOf: url) else {
            return nil
        }

        let base64String = imageData.base64EncodedString()
        let base64Data = Data(base64String.utf8)
        let relativeTimestamp = TimeInterval(screenshot.capturedAt - baseTimestamp)

        return FrameData(image: base64Data, timestamp: relativeTimestamp)
    }

    private func getFrameDescription(_ frame: FrameData, batchId: Int64?) async -> String? {
        let prompt = """
        Describe what you see on this computer screen in 1-2 sentences.
        Focus on: what application/site is open, what the user is doing, and any relevant details visible.
        Be specific and factual.

        GOOD EXAMPLES:
        ✓ "VS Code open with index.js file, writing a React component for user authentication."
        ✓ "Gmail compose window writing email to client@company.com about project timeline."
        ✓ "Slack conversation in #engineering channel discussing API rate limiting issues."

        BAD EXAMPLES:
        ✗ "User is coding" (too vague)
        ✗ "Looking at a website" (doesn't identify which site)
        ✗ "Working on computer" (completely non-specific)
        """

        guard let base64String = String(data: frame.image, encoding: .utf8) else {
            print("[\(providerType.displayName)] ⚠️ Failed to decode frame image — skipping frame")
            return nil
        }

        guard providerType.supportsVision else {
            // Fallback to text-only description if vision is not supported
            return nil
        }

        let content: [APIMessageContent] = [
            APIMessageContent(type: "text", text: prompt, image_url: nil),
            APIMessageContent(type: "image_url", text: nil, image_url: APIMessageContent.APIImageURL(url: "data:image/jpeg;base64,\(base64String)"))
        ]

        let request = APIChatRequest(
            model: model,
            messages: [
                APIChatMessage(role: "user", content: .contentArray(content))
            ]
        )

        do {
            let response = try await callChatAPI(request, operation: "describe_frame", batchId: nil, maxRetries: 1)
            return response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            print("[\(providerType.displayName)] ⚠️ describe_frame failed at \(frame.timestamp)s — skipping frame: \(error.localizedDescription)")
            return nil
        }
    }

    private func mergeFrameDescriptions(_ frameDescriptions: [(timestamp: TimeInterval, description: String)], batchStartTime: Date, videoDuration: TimeInterval, batchId: Int64?) async throws -> [Observation] {
        // Build a timeline description for the LLM
        var timelineText = "Timeline of screen activity:\n"
        for (timestamp, description) in frameDescriptions {
            let minutes = Int(timestamp) / 60
            let seconds = Int(timestamp) % 60
            timelineText += "\(String(format: "%02d:%02d", minutes, seconds)): \(description)\n"
        }

        let prompt = """
        You are analyzing a timeline of computer screen activity. Here's what happened:

        \(timelineText)

        Group these into 3-8 coherent activity segments. Each segment should represent a continuous purpose or activity.

        Return a JSON array in this format:
        [
          {
            "startTimestamp": "MM:SS",
            "endTimestamp": "MM:SS",
            "description": "What the user was doing during this period"
          }
        ]

        Guidelines:
        - Minimum segment length: 12 seconds
        - Maximum segment length: ~1 minute
        - Group related activities together
        - Brief interruptions (<12 seconds) should be included in the main activity
        - If the screen stays the same for 30+ seconds, note that the user was idle

        The video is \(String(format: "%02d:%02d", Int(videoDuration) / 60, Int(videoDuration) % 60)) long.
        """

        let request = APIChatRequest(
            model: model,
            messages: [
                APIChatMessage(role: "user", content: .string(prompt))
            ]
        )

        let response = try await callChatAPI(request, operation: "merge_frames", batchId: batchId)

        // Parse JSON response
        guard let data = response.choices.first?.message.content.data(using: .utf8) else {
            throw NSError(domain: "ChineseLLMProvider", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let videoTranscripts = try parseTranscripts(json)

        // Convert transcripts to observations
        let observations = videoTranscripts.compactMap { chunk -> Observation? in
            let startSeconds = parseVideoTimestamp(chunk.startTimestamp)
            let endSeconds = parseVideoTimestamp(chunk.endTimestamp)

            let startDate = batchStartTime.addingTimeInterval(TimeInterval(startSeconds))
            let endDate = batchStartTime.addingTimeInterval(TimeInterval(endSeconds))

            return Observation(
                id: nil,
                batchId: 0,
                startTs: Int(startDate.timeIntervalSince1970),
                endTs: Int(endDate.timeIntervalSince1970),
                observation: chunk.description,
                metadata: nil,
                llmModel: model,
                createdAt: Date()
            )
        }

        return observations
    }

    private func parseTranscripts(_ json: [[String: Any]]?) throws -> [VideoTranscript] {
        guard let json = json else {
            throw NSError(domain: "ChineseLLMProvider", code: 9, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }

        return try json.compactMap { dict -> VideoTranscript? in
            guard
                let startTimestamp = dict["startTimestamp"] as? String,
                let endTimestamp = dict["endTimestamp"] as? String,
                let description = dict["description"] as? String
            else {
                return nil
            }
            return VideoTranscript(startTimestamp: startTimestamp, endTimestamp: endTimestamp, description: description)
        }
    }

    private struct VideoTranscript {
        let startTimestamp: String
        let endTimestamp: String
        let description: String
    }

    // MARK: - Chat API

    private func callChatAPI(_ request: APIChatRequest, operation: String, batchId: Int64? = nil, maxRetries: Int = 3) async throws -> APIChatResponse {
        guard let url = URL(string: "\(endpoint)/chat/completions") else {
            throw NSError(domain: "ChineseLLMProvider", code: 15, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Set Authorization header based on provider type
        switch providerType {
        case .deepSeek, .alibaba:
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .zhipu:
            // Zhipu uses a different auth format: Bearer {apiKey}.{id}
            // We'll need to generate a token, but for now use the API key directly
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        let attempts = max(1, maxRetries)
        var lastError: Error?

        for attempt in 0..<attempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "ChineseLLMProvider", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                }

                if httpResponse.statusCode >= 400 && httpResponse.statusCode < 600 {
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    print("[\(providerType.displayName)] HTTP \(httpResponse.statusCode): \(errorMessage)")

                    if httpResponse.statusCode == 401 {
                        throw NSError(domain: "ChineseLLMProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid API key"])
                    } else if httpResponse.statusCode == 429 {
                        // Rate limited - wait and retry
                        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                        lastError = NSError(domain: "ChineseLLMProvider", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Rate limited"])
                        continue
                    } else if httpResponse.statusCode >= 500 {
                        // Server error - retry
                        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                        lastError = NSError(domain: "ChineseLLMProvider", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error"])
                        continue
                    }

                    throw NSError(domain: "ChineseLLMProvider", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                }

                let decoder = JSONDecoder()
                return try decoder.decode(APIChatResponse.self, from: data)

            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                }
            }
        }

        throw lastError ?? NSError(domain: "ChineseLLMProvider", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed after \(attempts) attempts"])
    }

    // MARK: - Activity Card Generation

    private func generateTitleAndSummary(observations: [Observation], categories: [LLMCategoryDescriptor], batchId: Int64?) async throws -> (String, String, String) {
        let observationsText = observations.map { observation in
            let date = Date(timeIntervalSince1970: TimeInterval(observation.startTs))
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "[\(formatter.string(from: date))] \(observation.observation)"
        }.joined(separator: "\n")

        let categoriesSection = categoriesSection(from: categories)

        let prompt = """
        You are analyzing someone's computer usage to create a timeline activity card. Here's what they did:

        \(observationsText)

        \(categoriesSection)

        Create a concise activity card with:
        1. A title (2-6 words describing the main activity)
        2. A summary (2-3 sentences describing what was accomplished)
        3. A category (pick one from the allowed categories above)

        Return JSON in this format:
        {
          "title": "Brief title",
          "summary": "What was accomplished",
          "category": "Category name"
        }

        Guidelines:
        - Focus on outcomes and achievements, not just actions
        - Be specific about what was worked on
        - Use the user's language and terminology
        - Group related activities together
        - Include meaningful details (topics, projects, tools)
        - Keep the title concise but descriptive
        """

        let request = APIChatRequest(
            model: model,
            messages: [
                APIChatMessage(role: "user", content: .string(prompt))
            ]
        )

        let response = try await callChatAPI(request, operation: "generate_title_summary", batchId: batchId)

        guard let content = response.choices.first?.message.content else {
            throw NSError(domain: "ChineseLLMProvider", code: 9, userInfo: [NSLocalizedDescriptionKey: "Empty response"])
        }

        // Parse JSON response
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String,
              let summary = json["summary"] as? String,
              let category = json["category"] as? String else {
            throw NSError(domain: "ChineseLLMProvider", code: 9, userInfo: [NSLocalizedDescriptionKey: "Failed to parse response"])
        }

        return (title, summary, category)
    }

    private func categoriesSection(from descriptors: [LLMCategoryDescriptor]) -> String {
        guard !descriptors.isEmpty else {
            return "USER CATEGORIES: No categories configured. Use consistent labels based on the activity story."
        }

        let allowed = descriptors.map { "\"\($0.name)\"" }.joined(separator: ", ")
        var lines: [String] = ["USER CATEGORIES (choose exactly one label):"]

        for (index, descriptor) in descriptors.enumerated() {
            var desc = descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if descriptor.isIdle && desc.isEmpty {
                desc = "Use when the user is idle for most of this period."
            }
            let suffix = desc.isEmpty ? "" : " — \(desc)"
            lines.append("\(index + 1). \"\(descriptor.name)\"\(suffix)")
        }

        if let idle = descriptors.first(where: { $0.isIdle }) {
            lines.append("Only use \"\(idle.name)\" when the user is idle for more than half of the timeframe. Otherwise pick the closest non-idle label.")
        }

        lines.append("Return the category exactly as written. Allowed values: [\(allowed)].")
        return lines.joined(separator: "\n")
    }

    private func normalizeCategory(_ raw: String, categories: [LLMCategoryDescriptor]) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return categories.first?.name ?? "" }
        let normalized = cleaned.lowercased()
        if let match = categories.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }) {
            return match.name
        }
        if let idle = categories.first(where: { $0.isIdle }) {
            let idleLabels = ["idle", "idle time", idle.name.lowercased()]
            if idleLabels.contains(normalized) {
                return idle.name
            }
        }
        return categories.first?.name ?? cleaned
    }

    private func calculateDurationInMinutes(from startTime: String, to endTime: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard let startDate = formatter.date(from: startTime),
              let endDate = formatter.date(from: endTime) else {
            return 0
        }

        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute], from: startDate, to: endDate)
        return components.minute ?? 0
    }
}
