import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Install screen: enter an Apple ID, choose a build, and install it in one
/// tap. While the pipeline runs, an animated step timeline and contextual
/// callouts guide the user through anything they need to do by hand.
struct ContentView: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var updateChecker: UpdateChecker
    /// Declared so every label on this screen redraws when the language changes.
    @EnvironmentObject private var loc: Localizer
    @Environment(\.openURL) private var openURL
    @State private var showSettings = false
    @State private var showImporter = false

    /// What the import picker will let you choose.
    ///
    /// Deliberately just "any file". iOS declares no UTType for `.ipa`, so the
    /// obvious `UTType(filenameExtension: "ipa")` mints a *dynamic* type — and a
    /// file only becomes selectable if the type its storage provider resolved
    /// happens to be that same dynamic type. When it isn't (iCloud Drive, a
    /// share sheet, a third-party provider often report the file as a zip or as
    /// plain data), the picker shows the file as normal and then silently
    /// ignores every tap on it: no selection, no dismissal, no callback.
    ///
    /// So the filter accepts everything and `Engine.importCustomIPA` does the
    /// real checking, by looking inside the file rather than trusting a label.
    private static let importableTypes: [UTType] = [.data]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header.cascadeItem(0)
                    if updateChecker.showBanner {
                        updateBanner.transition(.cardAppear)
                    }
                    appleIDCard.cascadeItem(1)
                    appCard.cascadeItem(2)
                    // Most-blocking requirement first: an unsupported iOS can't
                    // be worked around at all, so it pre-empts the other two.
                    // Then Wi-Fi, the prerequisite for the tunnel: no Wi-Fi →
                    // Wi-Fi callout; Wi-Fi but no tunnel → loopback-VPN callout;
                    // all three fine → none.
                    if !engine.isRunning {
                        if !engine.osSupported {
                            osRequirement.cascadeItem(3)
                        } else if !engine.wifiConnected {
                            wifiRequirement.cascadeItem(3)
                        } else if !engine.vpnConnected {
                            vpnRequirement.cascadeItem(3)
                        }
                    }
                    installButton.cascadeItem(4)
                    if showProgress {
                        progressCard.transition(.cardAppear)
                    }
                    if let pin = engine.pairingPIN {
                        pinCallout(pin).transition(.cardAppear)
                    }
                    if let guide = engine.guide {
                        guideCallout(guide).transition(.cardAppear)
                    }
                    if showError, let error = engine.lastError {
                        errorCallout(error).transition(.cardAppear)
                    }
                    if engine.finished {
                        successCallout.transition(.cardAppear)
                    }
                    // After a LiveContainer + SideStore install, the user still
                    // needs to import SideStore's certificate into LiveContainer.
                    if engine.finished, engine.installedIsLiveContainer {
                        guideCallout(Guides.liveContainerImport).transition(.cardAppear)
                    }
                    footer.cascadeItem(5)
                }
                .padding(20)
                // Each modifier watches one piece of state so a change animates
                // only its own card swap rather than the whole screen.
                .animation(.smooth(duration: 0.35), value: updateChecker.showBanner)
                .animation(.smooth(duration: 0.35), value: engine.vpnConnected)
                .animation(.smooth(duration: 0.35), value: engine.wifiConnected)
                .animation(.smooth(duration: 0.35), value: showProgress)
                .animation(.smooth(duration: 0.35), value: engine.pairingPIN)
                .animation(.smooth(duration: 0.35), value: engine.guide?.title)
                .animation(.smooth(duration: 0.35), value: showError)
                .animation(.smooth(duration: 0.4, extraBounce: 0.12), value: engine.finished)
                .animation(.smooth(duration: 0.35), value: engine.deviceSummary)
                .animation(.smooth(duration: 0.3), value: engine.isRunning)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppBackground())
            .toolbar { settingsToolbarItem(isPresented: $showSettings) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            // Attached here rather than on the card that owns the button: the
            // card carries `.disabled(engine.isRunning)`, and a presentation
            // inherits the environment of wherever its modifier lives, which
            // can leave the picked file unresponsive to taps.
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: Self.importableTypes) { result in
                switch result {
                case let .success(url):  engine.importCustomIPA(from: url)
                case let .failure(error): engine.log("⛔️ Import cancelled: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Derived visibility

    private var showProgress: Bool {
        engine.isRunning || engine.overallProgress > 0 || engine.finished
    }

    private var showError: Bool {
        engine.lastError != nil && !engine.isRunning
    }

    // MARK: Header

    private var header: some View {
        BrandHeader(icon: "arrow.down.app.fill", image: "AppLogo", title: "SideInstaller",
                    animateIcon: engine.isRunning) {
            statusPill
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
                .id(statusPillID)
        }
    }

    /// A stable identity so the pill cross-fades when its meaning changes.
    private var statusPillID: String {
        engine.deviceSummary ?? (engine.vpnConnected ? "up" : "down")
    }

    @ViewBuilder
    private var statusPill: some View {
        if let summary = engine.deviceSummary {
            StatusPill(text: summary, systemImage: "iphone", color: .green)
        } else if engine.vpnConnected {
            StatusPill(text: L("Tunnel connected"), systemImage: "checkmark.shield.fill", color: .green)
        } else {
            StatusPill(text: L("Tunnel off"), systemImage: "shield.slash.fill", color: .red)
        }
    }

    // MARK: Footer

    /// A quiet brand credit at the foot of the screen, tucked below the flow so it
    /// stays visible without crowding the header.
    private var footer: some View {
        Text(L("an app by Frizzle"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
    }

    // MARK: Apple ID

    private var appleIDCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Apple ID", systemImage: "person.crop.circle.fill")
                TextField(L("Email"), text: $engine.appleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textFieldStyle(.plain)
                    .fieldBackground()
                SecureField(L("Password"), text: $engine.applePassword)
                    .textContentType(.password)
                    .textFieldStyle(.plain)
                    .fieldBackground()
            }
        }
        .disabled(engine.isRunning)
    }

    // MARK: Update banner

    /// Closable notice shown when GitHub advertises a newer version than this
    /// build (see `UpdateChecker`). Tapping the body opens the install page; the
    /// ✕ dismisses it for this launch.
    private var updateBanner: some View {
        CalloutCard(tint: Theme.accent) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Update available"))
                            .font(.subheadline.weight(.semibold))
                        Text(L("SideInstaller %@ is available — you're on %@.",
                               updateChecker.latestVersion ?? "", updateChecker.currentVersion))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button {
                        updateChecker.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(Circle().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    if let url = URL(string: UpdateChecker.installPageURL) { openURL(url) }
                } label: {
                    HStack(spacing: 4) {
                        Text(L("Get the latest version"))
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: App picker

    private var appCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(L("Install"), systemImage: "square.and.arrow.down.fill")
                Menu {
                    Picker(L("Install"), selection: $engine.installSource) {
                        ForEach(InstallSource.allCases) { src in
                            Text(src.displayName).tag(src)
                        }
                    }
                } label: {
                    HStack {
                        Text(engine.installSource.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .fieldBackground()
                    .contentShape(Rectangle())
                }

                // A custom IPA has no release to choose between, so the channel
                // picker gives its place up to the importer that replaces it.
                ZStack {
                    if engine.installSource == .custom {
                        importControl.transition(.opacity)
                    } else {
                        Picker(L("Release"), selection: $engine.releaseChannel) {
                            ForEach(ReleaseChannel.allCases) { channel in
                                Text(channel.displayName).tag(channel)
                            }
                        }
                        .pickerStyle(.segmented)
                        .transition(.opacity)
                    }
                }
                .animation(.smooth(duration: 0.28), value: engine.installSource)

                // Explicit Resign & Install affordance for imported IPAs
                if engine.installSource == .custom && engine.customIPAName != nil {
                    Button {
                        // Ensure we run the custom install pipeline (reuses existing signing logic)
                        engine.installSource = .custom
                        engine.runOneClick()
                    } label: {
                        HStack {
                            Image(systemName: "hammer.fill")
                            Text(L("Resign & Install"))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(gradient: Theme.brand, glow: Theme.accent))
                    .padding(.top, 8)
                    .disabled(engine.isRunning)
                }
            }
        }
        .disabled(engine.isRunning)
    }

    /// Import button, which doubles as the readout of what's loaded: once a file
    /// is in, its name is the label, so the card always answers "which IPA will
    /// this install?" without a second row of text.
    private var importControl: some View {
        Button { showImporter = true } label: {
            HStack(spacing: 8) {
                Image(systemName: engine.customIPAName == nil
                      ? "square.and.arrow.down" : "checkmark.circle.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(engine.customIPAName == nil ? Color.secondary : Theme.accent2)
                Text(engine.customIPAName ?? L("Import .ipa"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer()
                if engine.customIPAName != nil {
                    Text(L("Replace"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent2)
                }
            }
            .fieldBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Primary action

    private var installButton: some View {
        Button {
            if engine.isRunning { engine.cancelOneClick() } else { engine.runOneClick() }
        } label: {
            HStack(spacing: 10) {
                if engine.isRunning {
                    ProgressView().tint(.white)
                    Text(L("Cancel"))
                } else {
                    Image(systemName: engine.finished ? "arrow.clockwise" : "square.and.arrow.down.fill")
                        .contentTransition(.symbolEffect(.replace))
                    Text(engine.finished ? L("Reinstall")
                                         : L("Install %@", engine.installSource.shortName))
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle(
            gradient: engine.isRunning
                ? LinearGradient(colors: [.red, Color(red: 0.9, green: 0.3, blue: 0.35)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)
                : Theme.brand,
            glow: engine.isRunning ? .red : Theme.accent))
        .animation(.smooth(duration: 0.3), value: engine.isRunning)
    }

    // MARK: iOS version requirement

    /// Shown above the Install button on an iPhone older than the minimum iOS.
    /// Unlike the Wi-Fi and loopback-VPN callouts this one isn't a "do this and
    /// carry on" — the install can't run here at all — so it replaces both.
    private var osRequirement: some View {
        CalloutCard(tint: .red) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "iphone.gen3.slash")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("iOS %@ required", Engine.minimumOSText))
                        .font(.subheadline.weight(.semibold))
                    Text(L("This iPhone runs iOS %@, which SideInstaller can't install on. Update to iOS %@ or later in Settings › General › Software Update.",
                           engine.osVersionText, Engine.minimumOSText))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // (rest of file unchanged...)
