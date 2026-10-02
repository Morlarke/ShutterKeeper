import AppKit
import ShutterKeeperCore
import SwiftUI

/// 底部胶片条：只显示当前文件夹内的片子，配对组只出现一项。
struct FilmstripView: View {
    let groups: [AssetGroup]
    let selectedID: String?
    let ratings: (AssetGroup) -> Int?
    let thumbnailSize: CGFloat
    let theme: AppTheme
    let cache: ThumbnailCache?
    let onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(groups) { group in
                        FilmstripItem(
                            group: group,
                            isSelected: group.id == selectedID,
                            rating: ratings(group),
                            size: thumbnailSize,
                            theme: theme,
                            cache: cache
                        )
                        .id(group.id)
                        .onTapGesture { onSelect(group.id) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: selectedID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .background(theme.panelBackground.opacity(0.5))
    }
}

private struct FilmstripItem: View {
    let group: AssetGroup
    let isSelected: Bool
    let rating: Int?
    let size: CGFloat
    let theme: AppTheme
    let cache: ThumbnailCache?

    @State private var image: CGImage?
    @State private var didFail = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if didFail {
                    Image(systemName: group.isVideo ? "film" : "photo")
                        .foregroundStyle(theme.secondaryText)
                } else {
                    ProgressView().controlSize(.small)
                }
                if group.isVideo {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(4)
                            Spacer()
                        }
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : theme.separator, lineWidth: isSelected ? 2 : 1)
            )

            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: (rating ?? 0) >= star ? "star.fill" : "star")
                        .font(.system(size: 7))
                        .foregroundStyle((rating ?? 0) >= star ? Color.yellow : theme.secondaryText.opacity(0.4))
                }
            }
            .frame(height: 8)
        }
        .frame(width: size)
        .task(id: taskKey) {
            await load()
        }
        .help(group.displayName)
    }

    private var taskKey: String {
        "\(group.id)|\(Int(size))"
    }

    private func load() async {
        guard image == nil, let cache else { return }
        guard let file = group.previewFile else { return }
        let maxPixel = Int(size * 2)
        let result = await cache.thumbnail(for: file, maxPixel: maxPixel)
        if let result {
            image = result
        } else {
            didFail = true
        }
    }
}
