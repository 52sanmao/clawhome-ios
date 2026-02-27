import SwiftUI

struct Attachment: Identifiable {
    let id = UUID()
    let type: AttachmentType
    let name: String
    let color: Color
}

enum AttachmentType: String, Codable {
    case image
    case file
    case audio
    case video

    var icon: String {
        switch self {
        case .image:
            return "photo"
        case .video:
            return "video.fill"
        case .file:
            return "doc.fill"
        case .audio:
            return "waveform"
        }
    }
}

enum ChatInputMode {
    case text
    case shortVoice
    case longVoice
}
