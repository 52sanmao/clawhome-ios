import SwiftUI

struct ChatScreenShell<TopBanner: View, Timeline: View, InputHeader: View, Composer: View>: View {
    let backgroundColor: Color
    let topBanner: TopBanner
    let timeline: Timeline
    let inputHeader: InputHeader
    let composer: Composer

    init(
        backgroundColor: Color = Color(.systemGroupedBackground),
        @ViewBuilder topBanner: () -> TopBanner,
        @ViewBuilder timeline: () -> Timeline,
        @ViewBuilder inputHeader: () -> InputHeader,
        @ViewBuilder composer: () -> Composer
    ) {
        self.backgroundColor = backgroundColor
        self.topBanner = topBanner()
        self.timeline = timeline()
        self.inputHeader = inputHeader()
        self.composer = composer()
    }

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBanner
                timeline
                inputHeader
                composer
            }
        }
    }
}

