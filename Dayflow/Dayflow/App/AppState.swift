import SwiftUI
import Combine

@MainActor
protocol AppStateManaging: ObservableObject {
    var isRecording: Bool { get }
    var objectWillChange: ObservableObjectPublisher { get }
}

@MainActor
final class AppState: ObservableObject, AppStateManaging {
    static let shared = AppState()

    private let recordingKey = "isRecording"
    private var shouldPersist = false
    private var pauseManagerActive = false  // Track if PauseManager is active
    private var cancellable: AnyCancellable?

    // @Published property for SwiftUI observation
    @Published var isRecording: Bool = false

    private init() {
        // Always start with false - AppDelegate will set the correct value
        isRecording = false
        NSLog("[AppState] Initialized with isRecording=false")
        logToFile("[AppState] Initialized with isRecording=false")

        // IMPORTANT: Set up the subscriber IMMEDIATELY in init
        // This ensures ALL changes to isRecording (including from SwiftUI bindings) are captured
        setupRecordingObserver()
    }

    private func setupRecordingObserver() {
        cancellable = $isRecording
            .dropFirst()  // Skip initial value during initialization
            .sink { [weak self] value in
                guard let self else { return }
                let message = "[AppState] isRecording changed to \(value), shouldPersist: \(self.shouldPersist), pauseManagerActive: \(self.pauseManagerActive)"
                NSLog(message)
                logToFile(message)
                // Only persist if allowed
                if self.shouldPersist && !self.pauseManagerActive {
                    UserDefaults.standard.set(value, forKey: self.recordingKey)
                    let saveMessage = "[AppState] Saved isRecording=\(value) to UserDefaults"
                    NSLog(saveMessage)
                    logToFile(saveMessage)
                }
            }
    }

    deinit {
        cancellable?.cancel()
    }

    /// Enable persistence after onboarding is complete
    func enablePersistence() {
        shouldPersist = true
        let message = "[AppState] Enabling persistence"
        NSLog(message)
        logToFile(message)
    }

    /// Set recording state and optionally persist it
    /// Note: Changes to isRecording will also be persisted automatically via the observer
    func setRecording(_ value: Bool, persist: Bool = true) {
        let message = "[AppState] setRecording called with value=\(value), persist=\(persist)"
        NSLog(message)
        logToFile(message)

        // Manually persist if requested and allowed
        if persist && shouldPersist && !pauseManagerActive {
            UserDefaults.standard.set(value, forKey: recordingKey)
            let saveMessage = "[AppState] Manually saved isRecording=\(value) to UserDefaults"
            NSLog(saveMessage)
            logToFile(saveMessage)
        }

        // Update the published property (observer will also try to persist, but that's OK)
        isRecording = value
    }

    /// Set recording state without persisting (used by PauseManager)
    func setRecordingWithoutPersisting(_ value: Bool) {
        let message = "[AppState] setRecordingWithoutPersisting called with value=\(value)"
        NSLog(message)
        logToFile(message)
        pauseManagerActive = true
        isRecording = value
        pauseManagerActive = false
        let completeMessage = "[AppState] setRecordingWithoutPersisting completed, isRecording=\(isRecording)"
        NSLog(completeMessage)
        logToFile(completeMessage)
    }

    private func logToFile(_ message: String) {
        if let url = URL(string: "file:///Users/liangchao/Library/Logs/Dayflow.log") {
            if let data = (message + "\n").data(using: .utf8) {
                if let fileHandle = try? FileHandle(forWritingTo: url) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }

    /// Get the saved recording preference, if any
    /// Returns nil if the key doesn't exist, false if explicitly set to false, true if explicitly set to true
    func getSavedPreference() -> Bool? {
        // Check if the key exists in UserDefaults
        if UserDefaults.standard.object(forKey: recordingKey) == nil {
            // Key doesn't exist - return nil so caller can use default value
            return nil
        }
        // Key exists - return the actual value (may be true or false)
        return UserDefaults.standard.bool(forKey: recordingKey)
    }
}
