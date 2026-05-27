import SwiftUI

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("hasOnboarded") private var hasOnboarded: Bool = false

    private enum Step: Hashable { case welcome, setup }
    @State private var step: Step = .welcome

    // Setup-screen draft state. Kept local so navigating back to Welcome
    // doesn't lose what the user typed.
    @State private var draftName: String = ""
    @State private var draftEmoji: String = EmojiPickerSheet.randomAnimal()
    @State private var draftCurrency: String = ""
    @State private var showingEmojiPicker = false
    @State private var showingCurrencyPicker = false
    @FocusState private var nameFocused: Bool

    private var currencyOptions: [String] { SupportedCurrencies.displayList }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.pageBackground.ignoresSafeArea()
                switch step {
                case .welcome:
                    welcomeScreen
                        .transition(.move(edge: .leading).combined(with: .opacity))
                case .setup:
                    setupScreen
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: step)
        }
        .onAppear {
            if draftCurrency.isEmpty { draftCurrency = defaultLocaleCurrency() }
        }
    }

    // MARK: Welcome

    private var welcomeScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("AppIconImage")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
                )
                .shadow(color: AppTheme.accent.opacity(0.18), radius: 16, x: 0, y: 8)

            VStack(spacing: 10) {
                Text("Welcome to TabKeep")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Split expenses with friends, no account needed.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Works offline · Multiple currencies · No sign-up")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
                step = .setup
            } label: {
                Text("Get started")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(AppTheme.accent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .accessibilityIdentifier("onboardingGetStartedButton")
        }
    }

    // MARK: Setup

    private var setupScreen: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroIdentity
                currencySummary
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture { nameFocused = false }
        .navigationTitle("Tell us about you")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    nameFocused = false
                    step = .welcome
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                        Text("Back")
                    }
                }
                .accessibilityIdentifier("onboardingBackButton")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            stickyCTA
        }
        .sheet(isPresented: $showingEmojiPicker) {
            EmojiPickerSheet(selection: $draftEmoji, category: .animals)
        }
        .sheet(isPresented: $showingCurrencyPicker) {
            AllCurrenciesSheet(selected: draftCurrency) { picked in
                draftCurrency = picked
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            nameFocused = true
        }
    }

    private var heroIdentity: some View {
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
                            Text(draftEmoji.isEmpty ? User.defaultEmoji : draftEmoji)
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
            .accessibilityIdentifier("onboardingEmojiButton")
            .accessibilityLabel("Profile emoji")
            .accessibilityValue(draftEmoji)

            TextField("Your name", text: $draftName)
                .multilineTextAlignment(.center)
                .font(.subheadline.weight(.semibold))
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($nameFocused)
                .accessibilityIdentifier("onboardingNameField")
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            nameFocused ? AppTheme.accent : AppTheme.borderHairline,
                            lineWidth: nameFocused ? 1.5 : 1
                        )
                )
                .shadow(
                    color: AppTheme.accent.opacity(nameFocused ? 0.18 : 0),
                    radius: 6,
                    x: 0,
                    y: 0
                )
                .animation(.easeInOut(duration: 0.15), value: nameFocused)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }

    private var currencySummary: some View {
        Button {
            showingCurrencyPicker = true
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default currency")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    HStack(spacing: 6) {
                        Text(displayedCurrencyCode)
                            .font(.subheadline.weight(.semibold))
                        Text("· \(SupportedCurrencies.displayName(for: displayedCurrencyCode))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.accent.opacity(0.7))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.cardBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboardingCurrencyButton")
    }

    private var stickyCTA: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.3)
            Button {
                complete()
            } label: {
                Text("Continue")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isContinueEnabled ? AppTheme.accent : AppTheme.accent.opacity(0.35))
                    )
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
            }
            .buttonStyle(.plain)
            .disabled(!isContinueEnabled)
            .accessibilityIdentifier("onboardingContinueButton")
        }
        .background(AppTheme.pageBackground)
    }

    private var displayedCurrencyCode: String {
        draftCurrency.isEmpty ? defaultLocaleCurrency() : draftCurrency
    }

    private var isContinueEnabled: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func complete() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        nameFocused = false
        let emoji = draftEmoji.isEmpty ? User.defaultEmoji : draftEmoji
        // Preserve serverID if the user was signed in during onboarding
        // (rare, but possible for re-onboarding flows).
        store.user = User(name: trimmed, emoji: emoji, serverID: store.user.serverID)
        let code = draftCurrency.isEmpty ? defaultLocaleCurrency() : draftCurrency
        Task { _ = try? await store.setDefaultCurrencyCode(code) }
        hasOnboarded = true
    }

    private func defaultLocaleCurrency() -> String {
        let code = Locale.current.currency?.identifier ?? "USD"
        return currencyOptions.contains(code) ? code : "USD"
    }
}
