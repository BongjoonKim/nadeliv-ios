import SwiftUI

struct LoginView: View {
    @Environment(AuthStore.self) private var auth

    @State private var userId = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    private enum Field { case userId, password }

    private var canSubmit: Bool {
        !userId.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isSubmitting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                form
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.Color.danger)
                        .accessibilityIdentifier("login.error")
                }
                submitButton
            }
            .padding(.horizontal, 24)
            .padding(.top, 72)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.Color.bg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NADELIV")
                .font(.caption.weight(.semibold))
                .tracking(3)
                .foregroundStyle(Theme.Color.accent)
            Text("Korea, beyond Seoul.")
                .font(Theme.Font.serif(34))
                .foregroundStyle(Theme.Color.text)
            Text("나들이브 계정으로 로그인하세요.")
                .font(.subheadline)
                .foregroundStyle(Theme.Color.textMuted)
        }
    }

    private var form: some View {
        VStack(spacing: 12) {
            TextField("", text: $userId, prompt: Text("아이디").foregroundStyle(Theme.Color.textFaint))
                .textContentType(.username)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focused, equals: .userId)
                .onSubmit { focused = .password }
                .modifier(InputFieldStyle())
                .accessibilityIdentifier("login.userId")

            SecureField("", text: $password, prompt: Text("비밀번호").foregroundStyle(Theme.Color.textFaint))
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focused, equals: .password)
                .onSubmit { Task { await submit() } }
                .modifier(InputFieldStyle())
                .accessibilityIdentifier("login.password")
        }
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            ZStack {
                if isSubmitting {
                    ProgressView().tint(Theme.Color.bg)
                } else {
                    Text("로그인").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(Theme.Color.bg)
            .background(Theme.Color.accent.opacity(canSubmit ? 1 : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .disabled(!canSubmit)
        .accessibilityIdentifier("login.submit")
    }

    private func submit() async {
        guard canSubmit else { return }
        focused = nil
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await auth.signIn(userId: userId.trimmingCharacters(in: .whitespaces), password: password)
        } catch APIError.server(401, _) {
            // 서버 401 문구는 영어 고정값이라 앱에서 한국어로 안내한다.
            errorMessage = "아이디 또는 비밀번호가 올바르지 않습니다."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct InputFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.Color.text)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Theme.Color.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Color.border2, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

#Preview {
    LoginView()
        .environment(AuthStore())
        .preferredColorScheme(.dark)
}
