//
//  ChatAttachmentCards.swift
//  contextgo
//
//  Reusable cards for message content rendering.
//

import Foundation
import SwiftUI

struct MediaLinkCard: View {
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: "paperclip.circle.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Attachment")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text("Open")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.12))
                    .foregroundColor(.blue)
                    .clipShape(Capsule())
            }
            .padding(10)
            .background(Color(.systemGray6))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.systemGray4), lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}
