import Foundation
import CoreGraphics

/// A kind of server that controls send to. Only HTTP so far; OSC, WebSocket or MQTT would be others.
protocol Output: AnyObject {
    /// `value` is the control's position, already scaled to the action's range.
    func send(_ action: ControlAction, _ value: Double)
}

/// Carries out actions: scrolling, requests to servers, and showing numbers on the controller's lights. It
/// makes an output for each server in the settings as it's first needed, and again after the settings change.
/// Everything runs on the main queue. windows/Outputs.cs is the same for the Windows version; change both together.
final class Outputs {
    private let servers: () -> [String: ServerConfig]
    private var made: [String: (config: ServerConfig, output: Output)] = [:]
    let scroll = ScrollOutput()
    private(set) var lights: Lights!

    /// Called after each request with the server's name (or "scroll" or "lights") and nil, or why it failed.
    var onResult: ((String, String?) -> Void)?

    init(servers: @escaping () -> [String: ServerConfig], outputPort: @escaping () -> String) {
        self.servers = servers
        lights = Lights(port: outputPort) { [weak self] error in self?.onResult?("lights", error) }
    }

    /// For a jog wheel: it turned this many ticks, already sped up and inverted as the control says.
    func turn(_ control: MidiControl, _ action: ControlAction, ticks: Double) {
        if action.isScroll { scroll.turn(action, ticks: ticks) }
        else if let type = action.type { onResult?(type, "\(control.name): there's no action type called \"\(type)\"") }
        else { onResult?(action.server ?? "", "\(control.name): a jog wheel can only scroll so far") }
    }

    /// For a fader or knob: it's at this position, from 0 at the bottom to 1 at the top.
    func setPosition(_ control: MidiControl, _ action: ControlAction, position: Double) {
        if action.isScroll {
            onResult?("scroll", "\(control.name): only a jog wheel can scroll")
            return
        }
        if let type = action.type {
            onResult?(type, "\(control.name): there's no action type called \"\(type)\"")
            return
        }
        let name = action.server ?? ""
        guard let config = servers()[name] else {
            onResult?(name, "There's no server called \"\(name)\" in the settings")
            return
        }
        var output: Output
        if let entry = made[name], entry.config === config {
            output = entry.output
        } else {
            switch config.type.lowercased() {
            case "http":
                output = HttpOutput(name: name, config: config,
                                    report: { [weak self] in self?.onResult?(name, $0) },
                                    answered: { [weak self] in self?.answered($0, $1) })
            default:
                onResult?(name, "\(name): there's no server type called \"\(config.type)\"")
                return
            }
            made[name] = (config, output)
        }
        let range = action.range ?? [0, 1]
        let low = range.first ?? 0, high = range.count > 1 ? range[1] : 1
        let scale = pow(10, Double(min(max(action.decimals ?? 0, 0), 15)))
        let value = ((low + position * (high - low)) * scale).rounded() / scale
        output.send(action, value)
        if let show = action.show, action.response == nil { lights.show(show, value) }   // nothing to wait for
    }

    /// A server answered a request that this action was part of.
    private func answered(_ action: ControlAction, _ answer: JSON?) {
        guard let show = action.show, let path = action.response else { return }
        if let number = Outputs.find(answer, path) { lights.show(show, number) }
        else { onResult?("lights", "The answer to \(action.method ?? "POST") \(action.path ?? "") has no number at \"\(path)\"") }
    }

    /// The number at a key in a JSON answer, or at keys separated by dots ("scope.index") in objects inside it.
    static func find(_ node: JSON?, _ path: String) -> Double? {
        var node = node
        for key in path.split(separator: ".", omittingEmptySubsequences: false) { node = node?[String(key)] }
        if case .number(let d) = node { return d }
        return nil
    }

    /// Forgets what belonged to the old settings.
    func reset() { scroll.reset() }
}

/// Shows numbers on the controller's lights: lights that many of a group, and turns them all off a moment after the last change.
final class Lights {
    private let output = MidiOutput()
    private let port: () -> String
    private let report: (String?) -> Void
    private var timers: [ObjectIdentifier: DispatchWorkItem] = [:]

    init(port: @escaping () -> String, report: @escaping (String?) -> Void) {
        self.port = port
        self.report = report
    }

    func show(_ show: ShowConfig, _ number: Double) {
        let count = Int(min(max(number.rounded(), 0), Double(show.lights.count)))
        for (i, light) in show.lights.enumerated() {
            if !set(light, i < count ? show.on : show.off) { return }
        }
        report(nil)

        timers.removeValue(forKey: ObjectIdentifier(show))?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timers.removeValue(forKey: ObjectIdentifier(show))
            for light in show.lights where !self.set(light, show.off) { return }
        }
        timers[ObjectIdentifier(show)] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, show.seconds), execute: work)
    }

    private func set(_ light: MidiMatch, _ value: Int) -> Bool {
        output.port = port()
        let error = output.send(light.status, light.data1, UInt8(min(max(value, 0), 127)))
        if let error { report(error) }
        return error == nil
    }
}

/// Scrolls the window under the mouse. While Shift is held, it scrolls sideways.
final class ScrollOutput {
    static let defaultPixelsPerTick = 4.0

    // Sub-pixel scroll carried over to the next tick, for each scroll action.
    private var carried: [ObjectIdentifier: (remainder: Double, horizontal: Bool)] = [:]

    var enabled = true

    func turn(_ action: ControlAction, ticks: Double) {
        guard enabled else { return }
        let distance = ticks * (action.pixelsPerTick ?? Self.defaultPixelsPerTick)
        let horizontal = keyboardShiftHeld

        // Carry fractions forward so low sensitivities still move, but drop them on a direction change.
        var (remainder, wasHorizontal) = carried[ObjectIdentifier(action)] ?? (0, false)
        if (remainder < 0) != (distance < 0) || horizontal != wasHorizontal { remainder = 0 }
        remainder += distance
        let whole = Int(remainder.rounded(.towardZero))
        carried[ObjectIdentifier(action)] = (remainder - Double(whole), horizontal)
        scroll(pixels: whole, horizontal: horizontal)
    }

    func reset() { carried.removeAll() }
}

func scroll(pixels: Int, horizontal: Bool = false) {
    guard pixels != 0 else { return }
    let clamped = Int32(max(-10_000, min(10_000, pixels)))
    // Positive vertical = up and positive horizontal = left, matching Shift + mouse wheel.
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: horizontal ? 0 : clamped, wheel2: horizontal ? clamped : 0, wheel3: 0)
    else { return }
    // Carry the real modifier keys. A posted event with different flags would make macOS (and us)
    // think Shift had been released partway through a Shift-scroll.
    var flags = CGEventSource.flagsState(.combinedSessionState)
    if keyboardShiftHeld { flags.insert(.maskShift) } else { flags.remove(.maskShift) }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

/// Whether either physical Shift key is down. Key state, unlike modifier flags,
/// isn't changed by the scroll events we post.
var keyboardShiftHeld: Bool {
    let leftShift: CGKeyCode = 56, rightShift: CGKeyCode = 60
    return CGEventSource.keyState(.hidSystemState, key: leftShift)
        || CGEventSource.keyState(.hidSystemState, key: rightShift)
}

/// Sends actions as HTTP requests, one at a time for each method and path. Changes made while a request
/// is on its way are merged into the next one, so a fast fader sweep doesn't pile up requests, and two
/// controls changing the same thing (say brightness and color temperature) share requests.
final class HttpOutput: Output {
    private struct Key: Hashable { var method: String; var path: String }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()
    private let name: String
    private let config: ServerConfig
    private let report: (String?) -> Void
    private let answered: (ControlAction, JSON?) -> Void
    private var pending: [Key: JSON?] = [:]                   // the body waiting to be sent
    private var pendingActions: [Key: [ControlAction]] = [:]  // the actions in it
    private var sending: Set<Key> = []

    /// `answered` is called with each action in a request that succeeded, and the server's answer.
    init(name: String, config: ServerConfig, report: @escaping (String?) -> Void,
         answered: @escaping (ControlAction, JSON?) -> Void) {
        self.name = name
        self.config = config
        self.report = report
        self.answered = answered
    }

    func send(_ action: ControlAction, _ value: Double) {
        let text = numberText(value)
        let key = Key(method: (action.method ?? "POST").uppercased(),
                      path: (action.path ?? "").replacingOccurrences(of: "$value", with: text))
        let body = action.body.map { Self.fill($0, value, text) }
        if case .some(.some(.object(var merged))) = pending[key], case .object(let fields)? = body {
            merged.merge(fields) { _, new in new }
            pending[key] = .object(merged)
        } else {
            pending[key] = .some(body)
        }
        var actions = pendingActions[key] ?? []
        if !actions.contains(where: { $0 === action }) { actions.append(action) }
        pendingActions[key] = actions
        if sending.insert(key).inserted { run(key) }
    }

    /// Puts the value into the body: a string that's exactly "$value" becomes the number, and "$value"
    /// inside a longer string is replaced as text.
    private static func fill(_ node: JSON, _ value: Double, _ text: String) -> JSON {
        switch node {
        case .object(let o): return .object(o.mapValues { fill($0, value, text) })
        case .array(let a): return .array(a.map { fill($0, value, text) })
        case .string(let s) where s.contains("$value"):
            return s == "$value" ? .number(value) : .string(s.replacingOccurrences(of: "$value", with: text))
        default: return node
        }
    }

    private func run(_ key: Key) {
        guard let body = pending.removeValue(forKey: key) else { sending.remove(key); return }
        let actions = pendingActions.removeValue(forKey: key) ?? []
        request(key.method, key.path, body) { [weak self] error, answer in
            guard let self else { return }
            self.report(error)
            if error == nil { for action in actions { self.answered(action, answer) } }
            self.run(key)
        }
    }

    /// Calls back on the main queue with why it failed, or nil and the server's answer (nil if it wasn't JSON).
    private func request(_ method: String, _ path: String, _ body: JSON?, done: @escaping (String?, JSON?) -> Void) {
        var request: URLRequest
        do {
            let base = try Substitutions.apply(config.url)
            guard let url = URL(string: Self.url(base, path)) else { throw SubstitutionError("\(base) isn't a URL") }
            request = URLRequest(url: url)
            for (header, value) in config.headers {
                request.setValue(try Substitutions.apply(value), forHTTPHeaderField: header)
            }
        } catch {
            done("\(name): \(error)", nil)
            return
        }
        request.httpMethod = method
        if let body {
            request.httpBody = try? JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let name = self.name
        Self.session.dataTask(with: request) { data, response, error in
            let result: (String?, JSON?)
            if let error = error as? URLError {
                result = error.code == .timedOut ? ("\(name) didn't answer", nil) : ("Couldn't reach \(name). Is it running?", nil)
            } else if let error {
                result = ("Couldn't reach \(name): \(error.localizedDescription)", nil)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let answer = data.flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(JSON.self, from: $0) }
                if (200..<300).contains(status) {
                    result = (nil, answer)
                } else if case .string(let message)? = answer?["error"] {
                    result = ("\(name): couldn't \(method) \(path): \(message)", nil)
                } else {
                    result = ("\(name): couldn't \(method) \(path): \(status)", nil)
                }
            }
            DispatchQueue.main.async { done(result.0, result.1) }
        }.resume()
    }

    /// The server's URL with the path added. Each part of the path is escaped, so names can have spaces.
    private static func url(_ url: String, _ path: String) -> String {
        if path.isEmpty { return url }
        let q = path.firstIndex(of: "?")
        let query = q.map { String(path[$0...]) } ?? ""
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let parts = (q.map { String(path[..<$0]) } ?? path).split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        var base = url
        while base.hasSuffix("/") { base.removeLast() }
        var rest = Substring(parts)
        while rest.hasPrefix("/") { rest.removeFirst() }
        return base + "/" + rest + query
    }
}

/// A number as text, without ".0" on whole numbers, for paths and bodies.
func numberText(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
}

struct SubstitutionError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Fills in ${file:PATH#key} (a top-level value from a JSON file, such as another program's settings)
/// and ${env:NAME} (an environment variable) in server URLs and headers.
enum Substitutions {
    private static let pattern = try! NSRegularExpression(pattern: #"\$\{(file|env):([^}]*)\}"#)
    private static var files: [String: (date: Date?, json: JSON?)] = [:]   // re-read when they change

    static func apply(_ s: String) throws -> String {
        var result = ""
        var last = s.startIndex
        for match in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            let whole = Range(match.range, in: s)!
            let kind = s[Range(match.range(at: 1), in: s)!], spec = String(s[Range(match.range(at: 2), in: s)!])
            result += s[last..<whole.lowerBound]
            if kind == "env" {
                guard let value = ProcessInfo.processInfo.environment[spec] else {
                    throw SubstitutionError("the environment variable \(spec) isn't set")
                }
                result += value
            } else {
                result += try fromFile(spec)
            }
            last = whole.upperBound
        }
        return result + s[last...]
    }

    private static func fromFile(_ spec: String) throws -> String {
        guard let hash = spec.lastIndex(of: "#") else { throw SubstitutionError("${file:\(spec)} needs #key after the file name") }
        let path = expandPath(String(spec[..<hash])), key = String(spec[spec.index(after: hash)...])

        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        var cached = files[path]
        if cached == nil || cached!.date != date {
            let json = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(JSON.self, from: $0) }
            cached = (date, json)
            files[path] = cached
        }
        guard case .object(let o)? = cached!.json else { throw SubstitutionError("couldn't read \(path)") }
        switch o[key] {
        case .string(let s)?: return s
        case .number(let n)?: return numberText(n)
        case .bool(let b)?: return b ? "true" : "false"
        default: throw SubstitutionError("\(path) has no \"\(key)\"")
        }
    }

    /// Expands ~ and environment variables written as $NAME.
    private static func expandPath(_ path: String) -> String {
        let env = ProcessInfo.processInfo.environment
        let variable = try! NSRegularExpression(pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#)
        var expanded = path
        for match in variable.matches(in: path, range: NSRange(path.startIndex..., in: path)).reversed() {
            let name = String(path[Range(match.range(at: 1), in: path)!])
            if let value = env[name] { expanded.replaceSubrange(Range(match.range, in: expanded)!, with: value) }
        }
        return (expanded as NSString).expandingTildeInPath
    }
}
