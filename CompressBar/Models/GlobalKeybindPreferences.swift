import Foundation
import Carbon

struct GlobalKeybindPreferences: Codable, Sendable {
    let function: Bool
    let control: Bool
    let command: Bool
    let shift: Bool
    let option: Bool
    let capsLock: Bool
    let carbonFlags: UInt32
    let characters: String
    let keyCode: UInt32
}

extension GlobalKeybindPreferences: CustomStringConvertible {
    var description: String {
        var parts = ""
        if control { parts += "\u{2303}" }   // ⌃
        if option { parts += "\u{2325}" }    // ⌥
        if shift { parts += "\u{21E7}" }     // ⇧
        if command { parts += "\u{2318}" }   // ⌘
        if capsLock { parts += "\u{21EA}" }  // ⇪
        if function { parts += "fn" }

        switch Int(keyCode) {
        case kVK_Return: parts += "\u{23CE}"         // ⏎
        case kVK_Delete: parts += "\u{232B}"         // ⌫
        case kVK_ForwardDelete: parts += "\u{2326}"  // ⌦
        case kVK_Space: parts += "\u{2423}"          // ␣
        case kVK_Escape: parts += "\u{238B}"         // ⎋
        case kVK_Tab: parts += "\u{21E5}"            // ⇥
        case kVK_UpArrow: parts += "\u{2191}"        // ↑
        case kVK_DownArrow: parts += "\u{2193}"      // ↓
        case kVK_LeftArrow: parts += "\u{2190}"      // ←
        case kVK_RightArrow: parts += "\u{2192}"     // →
        default:
            parts += characters.uppercased()
        }
        return parts
    }
}
