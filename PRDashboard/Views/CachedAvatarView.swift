import SwiftUI

struct CachedAvatarView: View {
    let url: URL?
    let authorInitial: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                initialsView
            }
        }
        .task(id: url) {
            if let url {
                image = await AvatarCache.shared.avatar(for: url)
            }
        }
    }

    private var initialsView: some View {
        ZStack {
            Circle()
                .fill(Color.gray.opacity(0.3))
            Text(String(authorInitial.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
}

#if DEBUG
struct CachedAvatarView_Previews: PreviewProvider {
    static var previews: some View {
        CachedAvatarView(
            url: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"),
            authorInitial: "X"
        )
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }
}
#endif
