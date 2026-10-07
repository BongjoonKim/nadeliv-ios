import SwiftUI

/// 비밀번호 변경. 웹 PasswordChange 와 같은 규칙 (새 비밀번호 6자 이상, 확인 일치).
struct PasswordChangeView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didChange = false

    static let minLength = 6

    private var validationMessage: String? {
        if !new.isEmpty, new.count < Self.minLength { return "새 비밀번호는 \(Self.minLength)자 이상이어야 해요." }
        if !confirm.isEmpty, new != confirm { return "새 비밀번호가 서로 달라요." }
        if !new.isEmpty, new == current { return "지금 쓰는 비밀번호와 다른 비밀번호를 입력해 주세요." }
        return nil
    }

    private var canSubmit: Bool {
        !current.isEmpty && new.count >= Self.minLength && new == confirm && new != current && !isSubmitting
    }

    var body: some View {
        Form {
            Section("현재 비밀번호") {
                SecureField("현재 비밀번호", text: $current)
                    .textContentType(.password)
                    .accessibilityIdentifier("password.current")
            }
            .listRowBackground(Theme.Color.surface)

            Section {
                SecureField("새 비밀번호", text: $new)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("password.new")
                SecureField("새 비밀번호 확인", text: $confirm)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("password.confirm")
            } header: {
                Text("새 비밀번호")
            } footer: {
                if let validationMessage {
                    Text(validationMessage).foregroundStyle(Theme.Color.danger)
                } else {
                    Text("\(Self.minLength)자 이상으로 입력해 주세요.")
                }
            }
            .listRowBackground(Theme.Color.surface)

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Text("비밀번호 바꾸기")
                        if isSubmitting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("password.submit")
            }
            .listRowBackground(Theme.Color.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Color.bg)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("비밀번호 변경")
        .navigationBarTitleDisplayMode(.inline)
        .alert("알림", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("비밀번호를 바꿨어요", isPresented: $didChange) {
            Button("확인") { dismiss() }
        } message: {
            Text("다음 로그인부터 새 비밀번호를 쓰세요.")
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await auth.api.changePassword(PasswordChangeRequest(currentPassword: current, newPassword: new))
            current = ""
            new = ""
            confirm = ""
            didChange = true
        } catch let error as APIError where error.isPasswordMismatch {
            errorMessage = "현재 비밀번호가 맞지 않아요."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
