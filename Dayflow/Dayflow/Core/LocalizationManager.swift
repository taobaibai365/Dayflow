//
//  LocalizationManager.swift
//  Dayflow
//
//  Manages app language localization with English and Chinese support
//

import Foundation
import SwiftUI
import Combine

/// Supported app languages
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }

    var nativeName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
}

/// Manager for handling app localization
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
            updateBundle()
        }
    }

    private var bundle: Bundle = Bundle.main

    private init() {
        if let languageCode = UserDefaults.standard.string(forKey: "appLanguage"),
           let language = AppLanguage(rawValue: languageCode) {
            self.currentLanguage = language
        } else {
            // Auto-detect system language
            let systemLang = Locale.current.language.languageCode?.identifier ?? "en"
            self.currentLanguage = systemLang.hasPrefix("zh") ? .chinese : .english
        }
        updateBundle()
    }

    private func updateBundle() {
        if let path = Bundle.main.path(forResource: currentLanguage.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            self.bundle = bundle
        } else {
            self.bundle = Bundle.main
        }

        // Notify all views to refresh
        objectWillChange.send()
    }

    func localizedString(_ key: String, comment: String = "") -> String {
        bundle.localizedString(forKey: key, value: comment, table: nil)
    }
}

/// SwiftUI view modifier for automatic localization refresh
extension View {
    func localized() -> some View {
        self.onReceive(LocalizationManager.shared.objectWillChange) { _ in
            // Force view refresh when language changes
        }
    }
}

/// Convenience property wrapper for localized strings
@propertyWrapper
struct LocalizedString {
    let key: String
    let comment: String

    var wrappedValue: String {
        LocalizationManager.shared.localizedString(key, comment: comment)
    }

    init(_ key: String, comment: String = "") {
        self.key = key
        self.comment = comment
    }
}
