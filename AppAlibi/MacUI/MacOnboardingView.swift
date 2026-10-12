import AlibiKit
import SwiftUI

/// The first-run tour, ported from ZuckOff's Mac onboarding: one card at a time
/// in a fixed window, arrows in their own gutters, dots underneath, a Skip
/// button, and the last page decides where the app lives. Nothing here blocks
/// moving on, and AppAlibi needs no permission prompts, so there are none.
struct MacOnboardingView: View {
    @AppStorage(MacPreferences.presentationKey) private var presentation: MacPresentation = .menuBar

    @State private var page = 0
    @State private var opensAtLogin = MacPreferences.opensAtLogin
    @State private var askingForNotifications = false
    private let notifier = Notifier.shared

    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    private enum Page: Int, CaseIterable {
        case welcome, records, source, running, notifications, home
    }

    private var pages: [Page] { Page.allCases }
    private var isLast: Bool { page == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLast {
                    Button("Skip", action: onFinish)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .frame(height: 20)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(spacing: 0) {
                arrow(back: true)
                ZStack {
                    card(pages[page])
                        .id(page)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                arrow(back: false)
            }

            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == page ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 16)
            .accessibilityHidden(true)

            ZStack {
                if isLast {
                    Button(action: onFinish) {
                        Text("Start Watching")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(height: 32)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(width: 600, height: 560)
        .task { await notifier.refreshStatus() }
        .tint(.orange)
        .background(
            Button("") { go(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .hidden()
        )
        .background(
            Button("") { go(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .hidden()
        )
    }

    private func go(_ step: Int) {
        let next = min(max(page + step, 0), pages.count - 1)
        guard next != page else { return }
        withAnimation(.easeInOut(duration: 0.3)) { page = next }
    }

    /// Always laid out, and only faded out where there is nowhere to go, so the
    /// card does not slide sideways on the first and last pages.
    private func arrow(back: Bool) -> some View {
        let hidden = back ? page == 0 : isLast
        return Button { go(back ? -1 : 1) } label: {
            Image(systemName: back ? "chevron.left" : "chevron.right")
                .scaledFont(16, weight: .semibold)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.thinMaterial))
                .overlay(Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(hidden ? 0 : 1)
        .disabled(hidden)
        .accessibilityHidden(hidden)
        .accessibilityLabel(Text(back ? "Back" : "Next"))
        .frame(width: 56)
    }

    // MARK: Pages

    @ViewBuilder
    private func card(_ page: Page) -> some View {
        switch page {
        case .welcome:
            template(
                title: "Welcome to AppAlibi",
                body: "macOS shows a dot while an app uses your camera, microphone or screen, then forgets. AppAlibi writes down which app it was, when, and for how long."
            ) {
                AnimatedSymbol(name: "eye", size: 80, effect: .pulse)
            }
        case .records:
            template(
                title: "What it keeps",
                body: "Every app has to account for itself."
            ) {
                AnimatedSymbol(name: "list.bullet.rectangle", size: 64, effect: .variableColor)
            } extra: {
                VStack(alignment: .leading, spacing: 8) {
                    point(Sensor.camera.symbolName, "Camera, microphone and screen recording sessions, with start time and length.")
                    point("lock.shield", "Permission checks for your folders, Full Disk Access, contacts and more, and whether macOS allowed them.")
                    point("square.stack.3d.up", "Apps and system services are kept apart, so the background noise of macOS stays out of the way.")
                }
                .padding(.horizontal, 40)
            }
        case .source:
            template(
                title: "How it knows",
                body: "AppAlibi reads the same macOS log entries that light up the privacy dots. The history stays in a database on this Mac. There is no account and nothing is uploaded."
            ) {
                AnimatedSymbol(name: "doc.text.magnifyingglass", size: 72)
            } extra: {
                Text("Not a guarantee. AppAlibi can only record what macOS logs, and a macOS update can change those entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
            }
        case .running:
            template(
                title: "Leave it running",
                body: "AppAlibi records while it runs, and catches up on the last few days of the log when it starts. Closing the window does not stop it. Quitting does."
            ) {
                HStack(spacing: 28) {
                    AnimatedSymbol(name: "laptopcomputer", size: 60)
                    AnimatedSymbol(name: "clock.arrow.circlepath", size: 60, effect: .breathe)
                }
            } extra: {
                Toggle(isOn: $opensAtLogin) {
                    Text("Open at login")
                    Text("Keeps the record going from the moment you log in.")
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 80)
                .onChange(of: opensAtLogin) { _, value in
                    MacPreferences.setOpensAtLogin(value)
                    opensAtLogin = MacPreferences.opensAtLogin
                }
            }
        case .notifications:
            template(
                title: "Hear about it as it happens",
                body: "AppAlibi can tell you when an app turns on your camera, microphone or screen for the first time, what used them while your Mac was locked, when an AI assistant gets control of your Mac, and sum up each day at \(defaultSummaryTime). Change any of these, or add a weekly summary, in Settings."
            ) {
                AnimatedSymbol(name: "bell.badge", size: 68, effect: .bounce)
            } extra: {
                notificationsControl
            }
        case .home:
            template(title: "Where should AppAlibi live?", body: nil) {
                Image.appIcon
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            } extra: {
                VStack(spacing: 10) {
                    ForEach(MacPresentation.allCases) { option in
                        presentationCard(option)
                    }
                }
                .padding(.horizontal, 40)
                Text("You can change this any time in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 18:00, or 6:00 PM, as the Mac shows times.
    private var defaultSummaryTime: String {
        let minute = AlertPreferences.defaultMinute
        let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// The permission prompt comes from a button, never on its own, so the
    /// tour reads the same whether the answer is yes or no.
    @ViewBuilder
    private var notificationsControl: some View {
        switch notifier.status {
        case .authorized, .provisional:
            Label("Notifications are on", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            VStack(spacing: 8) {
                Text("Notifications are turned off for AppAlibi.")
                    .foregroundStyle(.secondary)
                Button("Open System Settings") { notifier.openSystemSettings() }
            }
        default:
            VStack(spacing: 8) {
                Button {
                    askingForNotifications = true
                    Task {
                        AlertPreferences.enableDefaults()
                        await notifier.requestAuthorization()
                        if !notifier.isAuthorized { AlertPreferences.disableAll() }
                        askingForNotifications = false
                    }
                } label: {
                    Text("Turn On Notifications").frame(minWidth: 180)
                }
                .controlSize(.large)
                .disabled(askingForNotifications)
                Text("Or skip this and stay quiet. Nothing is lost, the history keeps recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func point(_ symbol: String, _ text: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func template<Icon: View, Extra: View>(
        title: LocalizedStringResource,
        body: LocalizedStringResource?,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        VStack(spacing: 20) {
            // A fixed box, so the title sits on the same line on every page.
            icon()
                .frame(height: 96)
                .padding(.top, 36)
            Text(title)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if let body {
                Text(body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
            }
            extra()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func presentationCard(_ option: MacPresentation) -> some View {
        let selected = presentation == option
        return Button {
            presentation = option
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Image(systemName: option.symbol)
                    .font(.title3)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.title).fontWeight(.medium)
                        if option == .menuBar {
                            CapsuleBadge(title: "Recommended")
                        }
                    }
                    Text(option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.08) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
