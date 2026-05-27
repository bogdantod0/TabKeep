import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AuthSession.self) private var authSession
    @Environment(\.openURL) private var openURL
    @State private var showingCurrencyPicker = false
    @State private var showingEmojiPicker = false
    /// Local edit buffer for profile fields. The TextField/emoji-picker
    /// bind to these so live typing doesn't immediately rewrite
    /// `store.user`. The "Save changes" button commits to the store +
    /// server in one shot. Initialized from `store.user` and re-synced
    /// whenever the underlying store changes (e.g., a /me refresh).
    @State private var draftName: String = ""
    @State private var draftEmoji: String = User.defaultEmoji
    @State private var savingProfile = false
    @FocusState private var nameFieldFocused: Bool

    /// True when the local draft differs from the persisted store value.
    private var hasProfileChanges: Bool {
        let trimmedDraft = draftName.trimmingCharacters(in: .whitespaces)
        let trimmedStore = store.user.name.trimmingCharacters(in: .whitespaces)
        return trimmedDraft != trimmedStore || draftEmoji != store.user.emoji
    }

    /// The server-side user when an Apple/Google provider is linked.
    /// `nil` when anonymous, `.loading`, or signed in without a provider —
    /// all of which keep the editable hero so the user can set a local
    /// display name before/while signing in.
    private var signedInUser: UserDTO? {
        if case .signedIn(let user, let providers, _) = authSession.state, !providers.isEmpty {
            return user
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroIdentity(name: $draftName, emoji: draftEmoji)
                if hasProfileChanges {
                    saveProfileBar
                }
                accountCard
                preferencesCard
                versionLabel
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, BottomTabBar.height + 24)
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
        .onAppear { syncDraftFromStore() }
        .onChange(of: store.user) { _, _ in syncDraftFromStore() }
        .sheet(isPresented: $showingCurrencyPicker) {
            AllCurrenciesSheet(selected: store.defaultCurrencyCode) { code in
                Task { try? await store.setDefaultCurrencyCode(code) }
            }
        }
        .sheet(isPresented: $showingEmojiPicker) {
            EmojiPickerSheet(selection: $draftEmoji, category: .animals)
        }
    }

    // MARK: - Hero identity

    private func heroIdentity(name: Binding<String>, emoji: String) -> some View {
        VStack(spacing: 14) {
            Button {
                showingEmojiPicker = true
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(AppTheme.accent.opacity(0.10), lineWidth: 1)
                        .frame(width: 96, height: 96)

                    ZStack(alignment: .bottomTrailing) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [AppTheme.accent.opacity(0.28), AppTheme.accent.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(Circle().strokeBorder(AppTheme.accent.opacity(0.18), lineWidth: 1))
                            Text(emoji.isEmpty ? User.defaultEmoji : emoji)
                                .font(.system(size: 40))
                        }
                        .frame(width: 80, height: 80)
                        .shadow(color: AppTheme.accent.opacity(0.18), radius: 10, x: 0, y: 5)

                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("Edit")
                        }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 9)
                        .background(Capsule().fill(AppTheme.accent))
                        .overlay(Capsule().strokeBorder(AppTheme.pageBackground, lineWidth: 3))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settingsEmojiButton")
            .accessibilityLabel("Change profile emoji")
            .accessibilityValue(emoji.isEmpty ? "None" : emoji)

            VStack(spacing: 6) {
                TextField("Your name", text: name)
                    .multilineTextAlignment(.center)
                    .font(.subheadline.weight(.semibold))
                    .textInputAutocapitalization(.words)
                    .focused($nameFieldFocused)
                    .submitLabel(.done)
                    .accessibilityIdentifier("settingsUserNameField")
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.cardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                nameFieldFocused ? AppTheme.accent : AppTheme.borderHairline,
                                lineWidth: nameFieldFocused ? 1.5 : 1
                            )
                    )
                    .shadow(
                        color: AppTheme.accent.opacity(nameFieldFocused ? 0.18 : 0),
                        radius: 6,
                        x: 0,
                        y: 0
                    )
                    .animation(.easeInOut(duration: 0.15), value: nameFieldFocused)
                    .frame(maxWidth: .infinity)

                if let email = signedInUser?.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Matched against group members by name")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Save profile

    private var saveProfileBar: some View {
        HStack(spacing: 10) {
            Button {
                syncDraftFromStore()
                nameFieldFocused = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Undo")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppTheme.borderHairlineStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(savingProfile)
            .accessibilityIdentifier("undoProfileChangesButton")

            Button {
                Task { await commitProfile() }
            } label: {
                HStack(spacing: 6) {
                    if savingProfile {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text(savingProfile ? "Saving…" : "Save")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(savingProfile || draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("saveProfileButton")
        }
    }

    private func syncDraftFromStore() {
        draftName = store.user.name
        draftEmoji = store.user.emoji
    }

    @MainActor
    private func commitProfile() async {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        savingProfile = true
        defer { savingProfile = false }
        await store.setProfile(name: trimmed, emoji: draftEmoji)
        // Re-sync the draft to whatever the store ended up with — server
        // canonicalization (trim, default emoji) should now match.
        syncDraftFromStore()
    }

    // MARK: - Account card

    private var accountCard: some View {
        AccountSection()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.cardBackground)
            )
    }

    // MARK: - Preferences card

    private var preferencesCard: some View {
        VStack(spacing: 0) {
            appearanceRowContent
            rowDivider
            currencyRowContent
            rowDivider
            contactRowContent
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.cardBackground)
        )
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 54)
    }

    private var appearanceRowContent: some View {
        preferenceRow(
            icon: "circle.lefthalf.filled",
            title: "Appearance"
        ) {
            Picker(
                "Appearance",
                selection: Binding<AppearancePreference>(
                    get: { store.appearance },
                    set: { store.setAppearance($0) }
                )
            ) {
                ForEach(AppearancePreference.allCases, id: \.self) { pref in
                    Text(pref.label).tag(pref)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(AppTheme.accent)
        }
        .accessibilityIdentifier("settingsAppearanceRow")
    }

    private var currencyRowContent: some View {
        Button {
            showingCurrencyPicker = true
        } label: {
            preferenceRow(
                icon: "dollarsign.circle.fill",
                title: "Default currency"
            ) {
                HStack(spacing: 8) {
                    Text("\(store.defaultCurrencyCode) · \(SupportedCurrencies.displayName(for: store.defaultCurrencyCode))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.accent.opacity(0.7))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settingsDefaultCurrencyRow")
    }

    private var contactRowContent: some View {
        Button {
            openContact()
        } label: {
            preferenceRow(
                icon: "envelope.fill",
                title: "Contact us",
                subtitle: "Send feedback or report an issue"
            ) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.accent.opacity(0.7))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settingsContactRow")
    }

    @ViewBuilder
    private func preferenceRow<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func openContact() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "office@appssemble.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "TabKeep — feedback"),
            URLQueryItem(name: "body", value: """


            ---
            App version: \(appVersion) (\(appBuild))
            """)
        ]
        if let url = components.url {
            openURL(url)
        }
    }

    private var versionLabel: some View {
        Text("Version \(appVersion) (\(appBuild))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .accessibilityIdentifier("settingsVersionLabel")
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

}
