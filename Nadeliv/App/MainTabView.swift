import SwiftUI

/// 로그인 후 메인 탭. 여행(앨범) 탭이 첫 화면이다.
struct MainTabView: View {
    let user: CurrentUser

    var body: some View {
        TabView {
            TravelListView()
                .tabItem { Label("여행", systemImage: "suitcase") }
            ProfileView(user: user)
                .tabItem { Label("프로필", systemImage: "person.crop.circle") }
        }
    }
}
