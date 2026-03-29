import SwiftUI

struct FLFullBleedImage: View {
  let uiImage: UIImage?
  var height: CGFloat = AppTheme.Space.cardImageHeight
  var fadeToColor: Color = AppTheme.surface
  var showBookmark: Bool = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      if let uiImage {
        Image(uiImage: uiImage)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity, maxHeight: height)
          .clipped()
      } else {
        LinearGradient(
          colors: [AppTheme.heroLight, AppTheme.heroMid],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        .frame(maxWidth: .infinity, maxHeight: height)
        .overlay {
          Image(systemName: "fork.knife")
            .font(.system(size: 36, weight: .medium))
            .foregroundStyle(.white.opacity(0.3))
        }
      }

      // Bottom fade gradient
      VStack {
        Spacer()
        LinearGradient(
          colors: [fadeToColor.opacity(0), fadeToColor],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: height * 0.4)
      }

      // Bookmark overlay
      if showBookmark {
        Image(systemName: "bookmark")
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(.white)
          .padding(AppTheme.Space.sm)
          .background(.ultraThinMaterial, in: Circle())
          .padding(AppTheme.Space.md)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: height)
  }
}
