//
//  AppDelegate.swift
//  Dayflow
//

import AppKit
import ServiceManagement
import ScreenCaptureKit
import PostHog
import Sentry
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // Controls whether the app is allowed to terminate.
    // Default is false so Cmd+Q/Dock/App menu quit will be cancelled
    // and the app will continue running in the background.
    static var allowTermination: Bool = false

    // Flag set when app is opened via notification tap - skips video intro
    static var pendingNavigationToJournal: Bool = false
    private var statusBar: StatusBarController!
    private var recorder : ScreenRecorder!
    private var analyticsSub: AnyCancellable?
    private var powerObserver: NSObjectProtocol?
    private var deepLinkRouter: AppDeepLinkRouter?
    private var pendingDeepLinkURLs: [URL] = []
    private var pendingRecordingAnalyticsReason: String?
    private var heartbeatTimer: Timer?
    private var appLaunchDate: Date?
    private var foregroundStartTime: Date?

    override init() {
        UserDefaultsMigrator.migrateIfNeeded()
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let didOnboard = UserDefaults.standard.bool(forKey: "didOnboard")

        // Block termination by default; only specific flows enable it.
        AppDelegate.allowTermination = false

        // Configure crash reporting (Sentry)
        let info = Bundle.main.infoDictionary
        let SENTRY_DSN = info?["SentryDSN"] as? String ?? ""
        let SENTRY_ENV = info?["SentryEnvironment"] as? String ?? "production"
        if !SENTRY_DSN.isEmpty {
            SentrySDK.start { options in
                options.dsn = SENTRY_DSN
                options.environment = SENTRY_ENV
                // Enable debug logging in development (disable for production)
                #if DEBUG
                options.debug = true
                options.tracesSampleRate = 1.0  // 100% in debug for testing
                #else
                options.tracesSampleRate = 0.1  // 10% in prod to reduce noise
                #endif
                // Attach stack traces to all messages (helpful for debugging)
                options.attachStacktrace = true
                // Enable app hang detection with a 5-second threshold to reduce noise
                options.enableAppHangTracking = true
                options.appHangTimeoutInterval = 5.0
                // Increase breadcrumb limit for better debugging context
                options.maxBreadcrumbs = 200  // Default is 100
                // Enable automatic session tracking
                options.enableAutoSessionTracking = true
            }
            // Enable safe wrapper now that Sentry is initialized
            SentryHelper.isEnabled = true
        }

        // Configure analytics (prod only; default opt-in ON)
        let POSTHOG_API_KEY = info?["PHPostHogApiKey"] as? String ?? ""
        let POSTHOG_HOST = info?["PHPostHogHost"] as? String ?? "https://us.i.posthog.com"
        if !POSTHOG_API_KEY.isEmpty {
            AnalyticsService.shared.start(apiKey: POSTHOG_API_KEY, host: POSTHOG_HOST)
        }

        // App opened (cold start)
        AnalyticsService.shared.capture("app_opened", ["cold_start": true])

        // Start heartbeat for DAU tracking
        appLaunchDate = Date()
        startHeartbeat()

        // App updated check
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let lastBuild = UserDefaults.standard.string(forKey: "lastRunBuild")
        if let last = lastBuild, last != build {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            AnalyticsService.shared.capture("app_updated", ["from_version": last, "to_version": "\(version) (\(build))"])        
        }
        UserDefaults.standard.set(build, forKey: "lastRunBuild")
        statusBar = StatusBarController()
        LaunchAtLoginManager.shared.bootstrapDefaultPreference()
        deepLinkRouter = AppDeepLinkRouter(delegate: self)

        // Check if we've passed the screen recording permission step
        let onboardingStep = OnboardingStepMigration.migrateIfNeeded()
        // didOnboard was already declared at the start of applicationDidFinishLaunching

        // Seed recording flag low, then create recorder
        // IMPORTANT: Don't auto-start - we'll manually start after all initialization
        AppState.shared.setRecording(false, persist: false)
        recorder = ScreenRecorder(autoStart: false)  // Changed to false

        // Only attempt to start recording if we're past the screen step or fully onboarded
        // Steps: 0=welcome, 1=howItWorks, 2=llmSelection, 3=llmSetup, 4=categories, 5=screen, 6=completion
        if didOnboard || onboardingStep > 5 {
            // Onboarding complete - enable persistence and restore user preference
            AppState.shared.enablePersistence()

            NSLog("[AppDelegate] didOnboard=\(didOnboard), onboardingStep=\(onboardingStep)")

            // CRITICAL: If didOnboard is true, permission was already granted during onboarding
            // We can safely default to ON regardless of what CGPreflightScreenCaptureAccess() returns
            // (it may return false due to sandboxing issues even though permission is granted)
            let hasPermission = didOnboard || CGPreflightScreenCaptureAccess()
            NSLog("[AppDelegate] hasPermission=\(hasPermission) (didOnboard=\(didOnboard), CGPreflight=\(CGPreflightScreenCaptureAccess()))")

            if hasPermission {
                NSLog("[AppDelegate] ENTERED hasPermission=true branch")
                // IMPORTANT: If recording is currently false but we have permission, reset the state
                // so we can properly default to ON. This handles the case where recording was
                // disabled in a previous session (e.g., by PauseManager) and we want to restore
                // the default ON state when permission is granted.
                let currentRecording = UserDefaults.standard.object(forKey: "isRecording")
                NSLog("[AppDelegate] DEBUG: currentRecording=\(currentRecording.map { "\($0)" } ?? "nil")")
                if currentRecording as? Bool == false {
                    // Remove the stale false value so we can default to ON
                    UserDefaults.standard.removeObject(forKey: "isRecording")
                    NSLog("[AppDelegate] Removed stale isRecording=false to enable default ON state")
                }

                // Permission is already granted - restore saved preference or default to ON
                let savedPref = AppState.shared.getSavedPreference()
                NSLog("[AppDelegate] savedPref=\(savedPref.map { "\($0)" } ?? "nil")")

                // IMPORTANT: If saved preference is explicitly false, respect it.
                // Otherwise (nil or true), default to ON.
                let shouldRecord: Bool
                if let pref = savedPref {
                    // User has explicitly set a preference
                    shouldRecord = pref
                } else {
                    // No saved preference - default to ON when permission is granted
                    shouldRecord = true
                }

                NSLog("[AppDelegate] DEBUG: shouldRecord=\(shouldRecord)")

                // IMPORTANT: Immediately save to UserDefaults to prevent other code from overwriting
                // Then set the AppState after deep links are flushed
                UserDefaults.standard.set(shouldRecord, forKey: "isRecording")
                NSLog("[AppDelegate] Immediately saved isRecording=\(shouldRecord) to UserDefaults")

                // Flush deep links first, then set AppState
                flushPendingDeepLinks()

                // Now set AppState after deep links are processed
                AppState.shared.setRecording(shouldRecord)
                NSLog("[AppDelegate] Set AppState.isRecording to=\(AppState.shared.isRecording)")

                AnalyticsService.shared.capture("recording_toggled", ["enabled": AppState.shared.isRecording, "reason": "auto"])
            } else {
                NSLog("[AppDelegate] ENTERED hasPermission=false branch - recording will be disabled")
                // No permission - don't start recording and don't trigger any dialogs
                // The permission request will happen in the onboarding flow if needed
                AppState.shared.setRecording(false)
                NSLog("[AppDelegate] No permission, isRecording set to false")
                flushPendingDeepLinks()
            }
        } else {
            // Still in early onboarding, don't enable persistence yet
            // Keep recording off and don't persist this state
            AppState.shared.setRecording(false, persist: false)
            NSLog("[AppDelegate] Still in onboarding, isRecording set to false")
            flushPendingDeepLinks()
        }
        
        // Start the Gemini analysis background job
        setupGeminiAnalysis()

        // Start inactivity monitoring for idle reset
        InactivityMonitor.shared.start()

        // Start notification service for journal reminders
        NotificationService.shared.start()

        // Observe recording state
        analyticsSub = AppState.shared.$isRecording
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                let reason = self.pendingRecordingAnalyticsReason ?? "user"
                guard reason != "auto" else { return }
                self.pendingRecordingAnalyticsReason = nil
                AnalyticsService.shared.capture("recording_toggled", ["enabled": enabled, "reason": reason])
                AnalyticsService.shared.setPersonProperties(["recording_enabled": enabled])
            }

        powerObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppDelegate.allowTermination = true
            }
        }

        // Track foreground sessions for engagement analytics
        setupForegroundTracking()

        // IMPORTANT: Final check to ensure recording state is correct after all initialization
        // This prevents other components from overwriting the intended state
        if didOnboard || onboardingStep > 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let hasPermission = CGPreflightScreenCaptureAccess()
                if hasPermission {
                    let savedPref = UserDefaults.standard.object(forKey: "isRecording") == nil ? nil : UserDefaults.standard.bool(forKey: "isRecording")
                    let current = AppState.shared.isRecording
                    NSLog("[AppDelegate] Final check: saved=\(savedPref.map { "\($0)" } ?? "nil"), current=\(current), permission=\(hasPermission)")

                    // If permission is granted and no explicit "false" preference, enable recording
                    if savedPref != false && !current {
                        NSLog("[AppDelegate] Permission granted with no explicit disable - forcing enabled")
                        AppState.shared.setRecording(true)
                        NSLog("[AppDelegate] Forced isRecording to true")
                    }

                    // Start the recorder manually
                    if AppState.shared.isRecording {
                        self.recorder.start()
                        NSLog("[AppDelegate] Manually started recorder")
                    }
                }
            }
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.allowTermination {
            return .terminateNow
        }
        // Soft-quit: hide windows and remove Dock icon, but keep status item + background tasks
        NSApp.hide(nil)
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }
    
    // MARK: - Foreground Tracking

    private func setupForegroundTracking() {
        // Initialize with current state (app is active at launch)
        foregroundStartTime = Date()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.foregroundStartTime = Date()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startTime = self.foregroundStartTime else { return }
                let duration = Date().timeIntervalSince(startTime)
                self.foregroundStartTime = nil

                AnalyticsService.shared.capture("app_foreground_session", [
                    "duration_seconds": round(duration * 10) / 10  // 1 decimal place
                ])
            }
        }
    }

    // Start Gemini analysis as a background task
    private func setupGeminiAnalysis() {
        // Perform after a short delay to ensure other initialization completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            AnalysisManager.shared.startAnalysisJob()
            print("AppDelegate: Gemini analysis job started")
            AnalyticsService.shared.capture("analysis_job_started", [
                "provider": {
                    if let data = UserDefaults.standard.data(forKey: "llmProviderType"),
                       let providerType = try? JSONDecoder().decode(LLMProviderType.self, from: data) {
                        switch providerType {
                        case .geminiDirect: return "gemini"
                        case .dayflowBackend: return "dayflow"
                        case .ollamaLocal: return "ollama"
                        case .chatGPTClaude: return "chat_cli"
                        case .chineseLLM(let type, _, _): return type.rawValue
                        }
                    }
                    return "unknown"
                }()
            ])
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if deepLinkRouter == nil {
            pendingDeepLinkURLs.append(contentsOf: urls)
            return
        }

        for url in urls {
            _ = deepLinkRouter?.handle(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Checkpoint WAL to persist any pending database changes before quit
        // Using .truncate to also reset the WAL file for a clean state
        StorageManager.shared.checkpoint(mode: .truncate)

        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        if let observer = powerObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            powerObserver = nil
        }
        // If onboarding not completed, mark abandoned with last step
        let didOnboard = UserDefaults.standard.bool(forKey: "didOnboard")
        if !didOnboard {
            let stepIdx = OnboardingStepMigration.migrateIfNeeded()
            let stepName: String = {
                switch stepIdx {
                case 0: return "welcome"
                case 1: return "how_it_works"
                case 2: return "llm_selection"
                case 3: return "llm_setup"
                case 4: return "categories"
                case 5: return "screen_recording"
                case 6: return "completion"
                default: return "unknown"
                }
            }()
            AnalyticsService.shared.capture("onboarding_abandoned", ["last_step": stepName])
        }
        AnalyticsService.shared.capture("app_terminated")
    }

    private func flushPendingDeepLinks() {
        guard let router = deepLinkRouter, !pendingDeepLinkURLs.isEmpty else { return }
        let urls = pendingDeepLinkURLs
        pendingDeepLinkURLs.removeAll()
        for url in urls {
            _ = router.handle(url)
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        // Send initial heartbeat
        sendHeartbeat()

        // Schedule repeating timer every 12 hours
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 12 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        var props: [String: Any] = [:]
        if let launch = appLaunchDate {
            let sessionHours = Date().timeIntervalSince(launch) / 3600
            props["session_hours"] = round(sessionHours * 10) / 10  // 1 decimal place
        }
        AnalyticsService.shared.capture("app_heartbeat", props)
    }
}

extension AppDelegate: AppDeepLinkRouterDelegate {
    func prepareForRecordingToggle(reason: String) {
        pendingRecordingAnalyticsReason = reason
    }
}
