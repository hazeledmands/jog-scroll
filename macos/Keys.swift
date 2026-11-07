import Foundation
import CoreGraphics

/// A key and the modifier keys held with it, written like "ctrl+shift+option+p". Keys are where they are on a
/// US keyboard, so on other layouts a letter is the key in that letter's US place.
/// windows/Keys.cs is the same for the Windows version; change both together.
struct KeyCombo: Equatable, CustomStringConvertible {
    var key: CGKeyCode
    var flags: CGEventFlags

    init(key: CGKeyCode, flags: CGEventFlags) {
        self.key = key
        self.flags = flags
    }

    struct ParseError: Error, CustomStringConvertible { var description: String }

    init(_ text: String) throws {
        var key: CGKeyCode?
        var flags: CGEventFlags = []
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for part in parts {
            if let modifier = Self.modifiers[part] { flags.insert(modifier); continue }
            guard let code = Self.keys[part] else {
                throw ParseError(description: part.isEmpty ? "\"\(text)\" is missing a key" : "there's no key called \"\(part)\" (in \"\(text)\")")
            }
            guard key == nil else { throw ParseError(description: "\"\(text)\" has more than one key that isn't a modifier") }
            key = code
        }
        guard let key else { throw ParseError(description: "\"\(text)\" only has modifier keys") }
        self.key = key
        self.flags = flags
    }

    var description: String { "key \(key) with flags \(flags.rawValue)" }

    static let modifiers: [String: CGEventFlags] = [
        "ctrl": .maskControl, "control": .maskControl,
        "shift": .maskShift,
        "option": .maskAlternate, "opt": .maskAlternate, "alt": .maskAlternate,
        "cmd": .maskCommand, "command": .maskCommand,
    ]

    // macOS virtual key codes, from HIToolbox's Events.h (kVK_ANSI_A and so on).
    static let keys: [String: CGKeyCode] = {
        var k: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
            "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        for (i, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() { k["f\(i + 1)"] = CGKeyCode(code) }
        return k
    }()
}

/// Carries out a button's actions, which press key combinations as if they were typed: the key goes down and up
/// with the modifier keys held.
final class KeyOutput {
    /// What presses them. Tests replace it.
    var post: (KeyCombo) -> Void = KeyOutput.press
    private let report: (String, String?) -> Void

    /// `report` is called after each action with what it went to and nil, or why it failed.
    init(report: @escaping (String, String?) -> Void) { self.report = report }

    /// The button was pressed (`down`) or let go.
    func press(_ control: MidiControl, _ action: ControlAction, down: Bool) {
        guard action.isKeys else {
            if action.isScroll { report("scroll", "\(control.name): only a jog wheel can scroll") }
            else if let type = action.type { report(type, "\(control.name): there's no action type called \"\(type)\"") }
            else { report(action.server ?? "", "\(control.name): a button can only press keys so far") }
            return
        }
        let on = (action.on ?? "press").lowercased()
        guard ["press", "release", "both"].contains(on) else {
            report("keys", "\(control.name): \"on\" is \"\(action.on ?? "")\", and it can be \"press\", \"release\" or \"both\"")
            return
        }
        guard on == "both" || on == (down ? "press" : "release") else { return }
        do {
            post(try KeyCombo(action.keys ?? ""))
            report("keys", nil)
        } catch {
            report("keys", "\(control.name): \(error)")
        }
    }

    static func press(_ combo: KeyCombo) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: combo.key, keyDown: down) else { return }
            event.flags = combo.flags
            event.post(tap: .cghidEventTap)
        }
    }
}
