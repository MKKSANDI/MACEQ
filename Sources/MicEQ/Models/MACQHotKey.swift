import AppKit
import Carbon
import Foundation

struct MACQHotKey: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = Self.carbonModifiers(from: modifierFlags)
    }

    var displayString: String {
        let modifierText = Self.displayText(forCarbonModifiers: modifiers)
        let keyText = Self.keyName(for: keyCode)
        return modifierText.isEmpty ? keyText : "\(modifierText)\(keyText)"
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let clean = flags.intersection(.deviceIndependentFlagsMask)
        var value: UInt32 = 0
        if clean.contains(.control) { value |= UInt32(controlKey) }
        if clean.contains(.option) { value |= UInt32(optionKey) }
        if clean.contains(.shift) { value |= UInt32(shiftKey) }
        if clean.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    private static func displayText(forCarbonModifiers modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        return parts.joined()
    }

    static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
        50: "`", 51: "Delete", 53: "Esc", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
        111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←",
        124: "→", 125: "↓", 126: "↑"
    ]
}
