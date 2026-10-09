import AppKit
import ServiceManagement
import SwiftUI
import os

// Adapted from ZuckOff's macOS target (ZuckoffCore/MacUI/MacFoundation.swift).

/// Where the app shows itself. One or the other, never neither: an app with
/// no Dock icon and no menu bar item would have no way back in.
enum MacPresentation: String, CaseIterable, Identifiable, Sendable {
    case menuBar
    case dock

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .menuBar: "Menu bar"
        case .dock: "Dock"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .menuBar: "An eye in the menu bar that fills while a sensor is in use. No Dock icon."
        case .dock: "A regular app with a Dock icon and the history window."
        }
    }

    var symbol: String {
        switch self {
        case .menuBar: "menubar.rectangle"
        case .dock: "dock.rectangle"
        }
    }
}

/// Plain UserDefaults keys, so the app struct and the settings views can bind
/// with `@AppStorage` and the app delegate can read the same values.
enum MacPreferences {
    static let presentationKey = "appalibi.mac.presentation"
    static let onboardingVersionKey = "appalibi.mac.onboardingVersionSeen"

    /// Raise when the onboarding changes enough that existing users should see it once more.
    static let onboardingVersion = 2

    private static let logger = Logger(subsystem: "com.szydlowsky.AppAlibi", category: "MacPreferences")

    static var presentation: MacPresentation {
        get { UserDefaults.standard.string(forKey: presentationKey).flatMap(MacPresentation.init(rawValue:)) ?? .menuBar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: presentationKey) }
    }

    static var needsOnboarding: Bool {
        UserDefaults.standard.integer(forKey: onboardingVersionKey) < onboardingVersion
    }

    static func markOnboardingSeen() {
        UserDefaults.standard.set(onboardingVersion, forKey: onboardingVersionKey)
    }

    /// Read from the system every time rather than stored, because the user
    /// can remove the login item in System Settings behind the app's back.
    static var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Login item change failed: \(String(describing: error))")
        }
    }
}

extension EnvironmentValues {
    /// Brings the history window forward. The app delegate owns the windows,
    /// so the menu bar item and the commands reach it through this.
    @Entry var openMainWindowAction: (() -> Void)?

    /// Shows the onboarding window again.
    @Entry var showOnboardingAction: (() -> Void)?
}

/// Brings the app forward for something the user just asked for.
///
/// Not `NSApp.activate()`. That call is cooperative since macOS 14: the system
/// may decline it while another app is in front, and an app with no Dock icon
/// is declined almost every time, so the window opened behind whatever the
/// user was looking at and seemed never to appear.
@MainActor
func activateForUserRequest() {
    NSApp.activate(ignoringOtherApps: true)
}

/// Opens the Settings window from anywhere, including from an app with no Dock
/// icon, which has to be made active first or the window opens behind.
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    let label: () -> Label

    var body: some View {
        Button {
            activateForUserRequest()
            openSettings()
        } label: {
            label()
        }
    }
}
