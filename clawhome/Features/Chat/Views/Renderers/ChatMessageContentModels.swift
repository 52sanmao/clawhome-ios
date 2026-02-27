//
//  ChatMessageContentModels.swift
//  contextgo
//
//  Shared content segment models for chat message rendering.
//

import Foundation

enum ChatMessageSegment {
    case markdown(String)
    case media(URL)
}
