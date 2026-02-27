//
//  ShimmerView.swift
//  contextgo
//
//  Shimmer loading animation for skeleton screens
//

import SwiftUI

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.white.opacity(0), location: 0),
                        .init(color: Color.white.opacity(0.3), location: 0.5),
                        .init(color: Color.white.opacity(0), location: 1)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 300)
                .mask(content)
            )
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - CLI Session Skeleton Screen

struct CLISessionSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            // Header skeleton
            headerSkeleton
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            // Messages skeleton
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { index in
                        if index % 2 == 0 {
                            // AI message (left aligned)
                            HStack {
                                messageBubbleSkeleton(width: 260, height: 80)
                                Spacer()
                            }
                        } else {
                            // User message (right aligned)
                            HStack {
                                Spacer()
                                messageBubbleSkeleton(width: 200, height: 60)
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Input bar skeleton
            inputBarSkeleton
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Components

    private var headerSkeleton: some View {
        HStack(spacing: 12) {
            // Avatar
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 32, height: 32)
                .shimmer()

            VStack(alignment: .leading, spacing: 6) {
                // Title
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 160, height: 16)
                    .shimmer()

                // Subtitle
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 120, height: 12)
                    .shimmer()
            }

            Spacer()

            // Status indicator
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 8, height: 8)
                .shimmer()
        }
    }

    private func messageBubbleSkeleton(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.gray.opacity(0.15))
            .frame(width: width, height: height)
            .shimmer()
    }

    private var inputBarSkeleton: some View {
        HStack(spacing: 12) {
            // Input field
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.gray.opacity(0.15))
                .frame(height: 40)
                .shimmer()

            // Send button
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 40, height: 40)
                .shimmer()
        }
    }
}

// MARK: - Preview

#Preview {
    CLISessionSkeleton()
}
