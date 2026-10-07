import SwiftUI

/// 회원 탈퇴 (App Store 5.1.1(v) — 앱 안에서 계정 삭제를 시작할 수 있어야 한다).
/// 비밀번호를 확인한 뒤 한 번 더 묻고, 성공하면 로그아웃해 로그인 화면으로 돌아간다.
struct AccountDeleteView: View {
    @Environment(AuthStore.self) private var auth

    @State private var password = ""
    @State private var isConfirming = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    bullet("trash", "지워지는 것", "이름, 이메일, 생일, 프로필 사진, 팔로우, 북마크")
                    bullet("text.bubble", "남는 것", "올린 글·댓글과 여행 앨범의 사진·영상은 \"Deleted user\" 이름으로 남아요. 지우고 싶다면 탈퇴 전에 직접 지워 주세요.")
                    bullet("person.crop.circle.badge.xmark", "다시 가입", "같은 아이디로는 다시 가입할 수 없어요. 이메일은 다시 쓸 수 있어요.")
                }
                .font(.subheadline)
                .padding(.vertical, 6)
            } header: {
                Text("탈퇴하면")
            } footer: {
                Text("탈퇴는 되돌릴 수 없어요.")
            }
            .listRowBackground(Theme.Color.surface)

            Section("비밀번호 확인") {
                SecureField("비밀번호", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("accountDelete.password")
            }
            .listRowBackground(Theme.Color.surface)

            Section {
                Button(role: .destructive) {
                    isConfirming = true
                } label: {
                    HStack {
                        Text("계정 삭제")
                        if isDeleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .foregroundStyle(password.isEmpty || isDeleting ? Theme.Color.textFaint : Theme.Color.danger)
                .disabled(password.isEmpty || isDeleting)
                .accessibilityIdentifier("accountDelete.submit")
            }
            .listRowBackground(Theme.Color.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Color.bg)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("계정 삭제")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("정말 계정을 삭제할까요?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("계정 삭제", role: .destructive) {
                Task { await delete() }
            }
            .accessibilityIdentifier("accountDelete.confirm")
            Button("취소", role: .cancel) {}
        } message: {
            Text("개인정보가 지워지고 바로 로그아웃돼요. 되돌릴 수 없어요.")
        }
        .alert("알림", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func bullet(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.Color.textFaint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.Color.text)
                Text(text).foregroundStyle(Theme.Color.textMuted)
            }
        }
    }

    private func delete() async {
        guard !password.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await auth.api.deleteMyAccount(password: password)
            auth.signOut()
        } catch let error as APIError where error.isPasswordMismatch {
            errorMessage = "비밀번호가 맞지 않아요."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
