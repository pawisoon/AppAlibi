import AlibiKit
import AppKit
import SwiftUI

/// Window identifiers for the scenes below.
enum MacScene {
    static let main = "history"
    static let onboarding = "onboarding"
}

/// Window and presentation handling follow ZuckOff's macOS target
/// (Mac/ZuckoffMacApp.swift): every window is a SwiftUI scene, and the app
/// delegate opens them through actions handed over by whichever scene appears first.
@main
struct AppAlibiApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @AppStorage(MacPreferences.presentationKey) private var presentation: MacPresentation = .menuBar

    var body: some Scene {
        Window("AppAlibi History", id: MacScene.main) {
            delegate.environment(HistoryView(model: delegate.model))
                .background(WindowActionBridge(delegate: delegate))
        }
        .defaultSize(width: 920, height: 580)
        // Dock mode opens the window at launch; menu bar mode waits to be asked.
        .defaultLaunchBehavior(delegate.mainWindowOpensAtLaunch ? .presented : .suppressed)

        // The title is never shown, the title bar is hidden, but it names the
        // window in Mission Control and the Window menu.
        Window("Welcome to AppAlibi", id: MacScene.onboarding) {
            delegate.environment(MacOnboardingView { delegate.finishOnboarding() })
                .background(WindowActionBridge(delegate: delegate))
                // No close button: closing the tour on a first run would leave an
                // app with nothing on screen. Skip is the way out.
                .windowDismissBehavior(.disabled)
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(MacPreferences.needsOnboarding ? .presented : .suppressed)

        MenuBarExtra(isInserted: menuBarInserted) {
            delegate.environment(MenuContentView(model: delegate.model))
        } label: {
            delegate.environment(MenuBarLabel(model: delegate.model))
                .background(WindowActionBridge(delegate: delegate))
        }
        .menuBarExtraStyle(.window)

        Settings {
            delegate.environment(SettingsView(model: delegate.model))
                .background(WindowActionBridge(delegate: delegate))
        }
        .commands {
            MacCommands(
                openMainWindow: { [delegate] in delegate.showMainWindow() },
                showOnboarding: { [delegate] in delegate.showOnboarding() }
            )
        }
    }

    /// Removing the item by Command-dragging it out of the menu bar would
    /// otherwise leave an app with no Dock icon and no menu bar item, so that
    /// gesture switches to Dock mode instead.
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { presentation == .menuBar },
            set: { inserted in
                if !inserted, presentation == .menuBar { presentation = .dock }
            }
        )
    }
}

struct MacCommands: Commands {
    let openMainWindow: @MainActor () -> Void
    let showOnboarding: @MainActor () -> Void

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("AppAlibi History") { openMainWindow() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Show Welcome Tour Again") { showOnboarding() }
        }
    }
}

/// Hands the scene's window actions to the delegate. The delegate opens
/// windows from places with no view to read them from: launch, a Dock click,
/// the end of onboarding.
private struct WindowActionBridge: View {
    let delegate: MacAppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                delegate.register(openWindow: openWindow, dismissWindow: dismissWindow)
            }
    }
}

/// Owns the model and applies the Dock or menu bar choice. Built once, before
/// launch finishes, so every scene reads the same model.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.shared

    private var openWindow: OpenWindowAction?
    private var dismissWindow: DismissWindowAction?
    /// Windows asked for before any scene had appeared, opened as soon as the actions arrive.
    private var pendingWindows: [String] = []
    private var defaultsObserver: NSObjectProtocol?
    private var appliedPresentation: MacPresentation?
    private var hasCompletedLaunch = false

    /// Read by the main window's scene when it is first built.
    let mainWindowOpensAtLaunch: Bool

    override init() {
        mainWindowOpensAtLaunch = !MacPreferences.needsOnboarding && MacPreferences.presentation == .dock
        super.init()
    }

    /// Every view gets the same window actions.
    func environment<Content: View>(_ content: Content) -> some View {
        content
            .environment(\.openMainWindowAction) { [weak self] in self?.showMainWindow() }
            .environment(\.showOnboardingAction) { [weak self] in self?.showOnboarding() }
    }

    func register(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        let first = self.openWindow == nil
        self.openWindow = openWindow
        self.dismissWindow = dismissWindow
        guard first else { return }
        let pending = pendingWindows
        pendingWindows.removeAll()
        pending.forEach(open)
    }

    // MARK: Lifecycle

    /// The notification delegate has to be in place before launch finishes, or
    /// a click on a notification that launched the app is lost.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Notifier.shared.open = { [weak self] destination in
            guard let self else { return }
            switch destination {
            case .sensors: model.historyTab = .sensors
            case .permissions: model.historyTab = .permissions
            case .summary(let period): model.showSummary(period)
            }
            showMainWindow()
        }
        Notifier.shared.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement keeps the Dock icon from flashing at launch. Onboarding
        // runs as a regular app so its window can take focus from whatever is
        // in front; Dock mode keeps that afterwards.
        NSApp.setActivationPolicy(MacPreferences.needsOnboarding ? .regular : .accessory)
        // Unlike ZuckOff there are no permission prompts to wait for, so
        // recording starts now and the catch-up runs during the tour.
        model.start()
        ReportScheduler.shared.start()
        if MacPreferences.needsOnboarding {
            activateForUserRequest()
        } else {
            completeLaunch()
        }
    }

    /// Runs once, after onboarding if there was one.
    private func completeLaunch() {
        guard !hasCompletedLaunch else { return }
        hasCompletedLaunch = true
        applyPresentation()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPresentation() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A Dock click, or opening the app again from Finder, brings the window
    /// back. A minimized window still counts in `hasVisibleWindows`, so that
    /// case is handled first.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if restoreMinimizedWindows() {
            activateForUserRequest()
        } else if !hasVisibleWindows {
            showMainWindow()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        LogReader.terminateAll()
    }

    @discardableResult
    private func restoreMinimizedWindows() -> Bool {
        let minimized = NSApp.windows.filter(\.isMiniaturized)
        minimized.forEach { $0.deminiaturize(nil) }
        return !minimized.isEmpty
    }

    // MARK: Presentation

    private func applyPresentation() {
        let presentation = MacPreferences.presentation
        guard presentation != appliedPresentation else { return }
        let isFirst = appliedPresentation == nil
        appliedPresentation = presentation
        switch presentation {
        case .menuBar:
            NSApp.setActivationPolicy(.accessory)
            // Dropping the Dock icon also deactivates the app, which would leave
            // an open window stranded behind everything else.
            if !isFirst { activateForUserRequest() }
        case .dock:
            NSApp.setActivationPolicy(.regular)
            // At launch the scene opens itself. A switch from Settings brings the
            // window forward so the new Dock icon has something to show.
            if !isFirst { showMainWindow() }
        }
    }

    // MARK: Windows

    func showMainWindow() { open(MacScene.main) }

    func showOnboarding() { open(MacScene.onboarding) }

    func finishOnboarding() {
        MacPreferences.markOnboardingSeen()
        let firstRun = !hasCompletedLaunch
        completeLaunch()
        // A first run ends on the history window in either mode. Otherwise menu
        // bar mode would end with nothing on screen, which reads as the app
        // having quit.
        if firstRun { showMainWindow() }
        // Closed through AppKit: with dismissal disabled on that window (so the
        // tour has no close button), dismissWindow is refused as well.
        NSApp.windows
            .filter { $0.identifier?.rawValue.hasPrefix(MacScene.onboarding) == true }
            .forEach { $0.close() }
    }

    private func open(_ id: String) {
        guard let openWindow else {
            pendingWindows.append(id)
            return
        }
        activateForUserRequest()
        openWindow(id: id)
        // Activation alone is not enough for an app with no Dock icon: the new
        // window can sit behind another app. Order it front on the next pass,
        // once the scene has made it.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }) else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
