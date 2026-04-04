import SwiftUI
import Kingfisher

struct CachedAvatarView: View {
    let url: URL?
    var size: CGFloat = 32
    var fallbackIcon: String = "person.fill"
    var fallbackColor: Color = .gray

    var body: some View {
        KFImage(url)
            .placeholder {
                Circle()
                    .fill(fallbackColor.opacity(0.3))
                    .overlay(
                        Image(systemName: fallbackIcon)
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(fallbackColor)
                    )
            }
            .retry(maxCount: 2, interval: .seconds(1))
            .fade(duration: 0.2)
            .cacheMemoryOnly(false)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

#Preview {
    HStack(spacing: 16) {
        CachedAvatarView(
            url: URL(string: "https://api.dicebear.com/9.x/bottts/png?seed=George&size=64"),
            size: 40
        )
        CachedAvatarView(
            url: URL(string: "https://api.dicebear.com/9.x/bottts/png?seed=David&size=64"),
            size: 32
        )
        CachedAvatarView(url: nil, size: 28, fallbackColor: .orange)
    }
    .padding()
    .background(Color(white: 0.1))
}
