// axhelper — background UI control helper for the DSH `desktop-bg` plugin.
//
// Protocol: `axhelper '<json>'` -> one JSON object on stdout.
// All accessibility work happens over AXUIElement APIs, which are independent
// of window z-order; the only z-order-sensitive operation is `click`, which
// posts a Quartz event to the target pid instead of the HID tap.

import Cocoa
import ApplicationServices

// MARK: - helpers

func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return err == .success ? v : nil
}

func axString(_ el: AXUIElement, _ name: String) -> String? {
    axAttr(el, name) as? String
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func axPoint(_ el: AXUIElement) -> CGPoint? {
    guard let v = axAttr(el, kAXPositionAttribute as String) else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}

func axSize(_ el: AXUIElement) -> CGSize? {
    guard let v = axAttr(el, kAXSizeAttribute as String) else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

func axRole(_ el: AXUIElement) -> String { axString(el, kAXRoleAttribute as String) ?? "?" }

func axLabel(_ el: AXUIElement) -> String {
    for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
        if let s = axString(el, key as String), !s.isEmpty { return s }
    }
    return ""
}

/// Breadth-first walk of the accessibility tree below `roots`.
/// Chromium prunes its tree when the window is not key, so callers must treat
/// a thin result as "the app chose not to expose this", not as "no such control".
func walk(_ roots: [AXUIElement], limit: Int = 6000) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var queue = roots
    var head = 0
    while head < queue.count && out.count < limit {
        let el = queue[head]
        head += 1
        out.append(el)
        queue.append(contentsOf: axChildren(el))
    }
    return out
}

func axWindows(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    return (axAttr(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
}

func windowFrame(_ win: AXUIElement) -> (CGPoint, CGSize)? {
    guard let p = axPoint(win), let s = axSize(win) else { return nil }
    return (p, s)
}

/// Largest window wins by default; `index` selects explicitly when a process
/// owns several ordinary windows.
func pickWindow(_ pid: pid_t, index: Int?) -> (AXUIElement, CGPoint, CGSize)? {
    let wins = axWindows(pid).compactMap { w -> (AXUIElement, CGPoint, CGSize)? in
        guard let f = windowFrame(w) else { return nil }
        return (w, f.0, f.1)
    }
    guard !wins.isEmpty else { return nil }
    if let i = index, i >= 0, i < wins.count { return wins[i] }
    return wins.max { $0.2.width * $0.2.height < $1.2.width * $1.2.height }
}

func jsonOut(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    jsonOut(["ok": false, "error": message])
    exit(1)
}

// MARK: - operations

func opWindows(_ pid: pid_t) -> [String: Any] {
    let wins = axWindows(pid)
    var list: [[String: Any]] = []
    for (i, w) in wins.enumerated() {
        guard let (p, s) = windowFrame(w) else { continue }
        list.append([
            "index": i,
            "title": axString(w, kAXTitleAttribute as String) ?? "",
            "x": p.x, "y": p.y, "width": s.width, "height": s.height,
        ])
    }
    return ["ok": true, "windows": list]
}

func textFields(_ pid: pid_t) -> [AXUIElement] {
    walk(axWindows(pid)).filter { axRole($0) == "AXTextField" }
}

func pickField(_ pid: pid_t, match: String?) -> (AXUIElement, String)? {
    var fields = textFields(pid)
    if let m = match, !m.isEmpty {
        fields = fields.filter { el in
            let hay = [
                axString(el, kAXDescriptionAttribute as String) ?? "",
                axString(el, kAXPlaceholderValueAttribute as String) ?? "",
                axString(el, kAXTitleAttribute as String) ?? "",
            ].joined(separator: " ")
            return hay.localizedCaseInsensitiveContains(m)
        }
    }
    // topmost field is almost always the search / address box
    guard let best = fields.min(by: { (axPoint($0)?.y ?? 0) < (axPoint($1)?.y ?? 0) }) else { return nil }
    return (best, axLabel(best))
}

func opFocus(_ pid: pid_t, match: String?) -> [String: Any] {
    guard let (field, label) = pickField(pid, match: match) else {
        return ["ok": false, "error": "no AXTextField reachable (the app may prune its tree while backgrounded)"]
    }
    let err = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    return ["ok": err == .success, "axError": Int(err.rawValue), "label": label]
}

let keyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49, "escape": 53, "esc": 53,
    "delete": 51, "backspace": 51, "forwarddelete": 117,
    "up": 126, "down": 125, "left": 123, "right": 124,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 23, "5": 22, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
    "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]

func modifierFlags(_ names: [String]) -> CGEventFlags {
    var flags: CGEventFlags = []
    for n in names.map({ $0.lowercased() }) {
        switch n {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: break
        }
    }
    return flags
}

func postKeystroke(_ pid: pid_t, keyCode: CGKeyCode, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { continue }
        e.flags = flags
        e.postToPid(pid)
        usleep(20_000)
    }
}

func typeUnicode(_ pid: pid_t, _ text: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for unit in Array(text.utf16) {
        var c = unit
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
            e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            e.postToPid(pid)
            usleep(25_000)
        }
    }
}

func opType(_ pid: pid_t, text: String, match: String?, clear: Bool) -> [String: Any] {
    guard let (field, label) = pickField(pid, match: match) else {
        return ["ok": false, "error": "no AXTextField reachable (the app may prune its tree while backgrounded)"]
    }
    let focusErr = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard focusErr == .success else {
        return ["ok": false, "error": "could not focus the field", "axError": Int(focusErr.rawValue)]
    }
    usleep(80_000)
    if clear {
        postKeystroke(pid, keyCode: 0, flags: .maskCommand) // cmd+a
        usleep(60_000)
        postKeystroke(pid, keyCode: 51, flags: [])          // delete
        usleep(60_000)
    }
    typeUnicode(pid, text)
    usleep(180_000)
    let value = axString(field, kAXValueAttribute as String) ?? ""
    return [
        "ok": true,
        "label": label,
        // AXValue read-back proves the control's value, NOT that a web renderer
        // committed it: treat Chromium results as "unverified" until a screenshot agrees.
        "valueAfter": value,
        "verified": "ax-value",
    ]
}

func opPress(_ pid: pid_t, label: String, role: String?) -> [String: Any] {
    let all = walk(axWindows(pid))
    var matches: [AXUIElement] = []
    for el in all {
        if let r = role, !r.isEmpty, axRole(el) != r { continue }
        let candidate = [
            axString(el, kAXTitleAttribute as String) ?? "",
            axString(el, kAXDescriptionAttribute as String) ?? "",
            axString(el, kAXValueAttribute as String) ?? "",
        ]
        if candidate.contains(where: { $0 == label }) { matches.append(el) }
    }
    guard let hit = matches.first else {
        return ["ok": false, "error": "no element labelled \(label)", "scanned": all.count]
    }
    let err = AXUIElementPerformAction(hit, kAXPressAction as CFString)
    return ["ok": err == .success, "axError": Int(err.rawValue), "role": axRole(hit), "matches": matches.count]
}

/// Press the smallest element under a window-local point that exposes AXPress.
/// This is the background equivalent of a click for web content: links and
/// buttons respond to it, plain text fields and canvases do not.
func opPressPoint(_ pid: pid_t, x: Double, y: Double, index: Int?) -> [String: Any] {
    guard let (_, origin, size) = pickWindow(pid, index: index) else {
        return ["ok": false, "error": "no window for pid \(pid)"]
    }
    guard x >= 0, y >= 0, x <= size.width, y <= size.height else {
        return ["ok": false, "error": "point outside window", "width": size.width, "height": size.height]
    }
    let target = CGPoint(x: origin.x + x, y: origin.y + y)
    var best: (AXUIElement, CGFloat)?
    for el in walk(axWindows(pid)) {
        guard let p = axPoint(el), let s = axSize(el) else { continue }
        guard s.width > 0, s.height > 0 else { continue }
        let frame = CGRect(origin: p, size: s)
        guard frame.contains(target) else { continue }
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(el, &actionNames) == .success,
              let actions = actionNames as? [String],
              actions.contains(kAXPressAction as String) else { continue }
        let area = s.width * s.height
        if best == nil || area < best!.1 { best = (el, area) }
    }
    guard let hit = best?.0 else {
        return ["ok": false, "error": "no pressable element under the point", "screenPoint": ["x": target.x, "y": target.y]]
    }
    let err = AXUIElementPerformAction(hit, kAXPressAction as CFString)
    return ["ok": err == .success, "axError": Int(err.rawValue), "role": axRole(hit),
            "label": axLabel(hit), "verified": "ax-action"]
}

func opClick(_ pid: pid_t, x: Double, y: Double, index: Int?) -> [String: Any] {
    guard let (_, origin, size) = pickWindow(pid, index: index) else {
        return ["ok": false, "error": "no window for pid \(pid)"]
    }
    guard x >= 0, y >= 0, x <= size.width, y <= size.height else {
        return ["ok": false, "error": "point outside window", "width": size.width, "height": size.height]
    }
    let p = CGPoint(x: origin.x + x, y: origin.y + y)
    let src = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { continue }
        e.postToPid(pid)
        usleep(40_000)
    }
    return [
        "ok": true,
        "screenPoint": ["x": p.x, "y": p.y],
        // Chromium drops mouse events for a window that is not key: this reports
        // dispatch, never activation.
        "verified": "dispatch-only",
    ]
}

func opKey(_ pid: pid_t, key: String, modifiers: [String]) -> [String: Any] {
    guard let code = keyCodes[key.lowercased()] ?? keyCodes[key] else {
        return ["ok": false, "error": "unsupported key \(key)"]
    }
    postKeystroke(pid, keyCode: code, flags: modifierFlags(modifiers))
    return ["ok": true, "keyCode": Int(code), "verified": "dispatch-only"]
}

func opProbe(_ pid: pid_t) -> [String: Any] {
    let all = walk(axWindows(pid))
    var roles: [String: Int] = [:]
    for el in all { roles[axRole(el), default: 0] += 1 }
    let fields = all.filter { axRole($0) == "AXTextField" }.map { el -> [String: Any] in
        ["label": axLabel(el), "value": axString(el, kAXValueAttribute as String) ?? "",
         "y": axPoint(el)?.y ?? 0]
    }
    return [
        "ok": true,
        "scanned": all.count,
        "roles": roles,
        "textFields": fields,
        "axTrusted": AXIsProcessTrusted(),
    ]
}

// MARK: - entry

let argv = CommandLine.arguments
guard argv.count >= 2, let data = argv[1].data(using: .utf8),
      let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    fail("usage: axhelper '<json>'")
}
guard let pidValue = req["pid"] as? Int, pidValue > 0 else { fail("missing pid") }
let pid = pid_t(pidValue)
let op = (req["op"] as? String) ?? ""

let result: [String: Any]
switch op {
case "windows": result = opWindows(pid)
case "focus": result = opFocus(pid, match: req["match"] as? String)
case "type":
    guard let text = req["text"] as? String else { fail("missing text") }
    result = opType(pid, text: text, match: req["match"] as? String, clear: req["clear"] as? Bool ?? false)
case "press":
    guard let label = req["label"] as? String else { fail("missing label") }
    result = opPress(pid, label: label, role: req["role"] as? String)
case "press_point":
    guard let x = req["x"] as? Double, let y = req["y"] as? Double else { fail("missing x/y") }
    result = opPressPoint(pid, x: x, y: y, index: req["window"] as? Int)
case "click":
    guard let x = req["x"] as? Double, let y = req["y"] as? Double else { fail("missing x/y") }
    result = opClick(pid, x: x, y: y, index: req["window"] as? Int)
case "key":
    guard let key = req["key"] as? String else { fail("missing key") }
    result = opKey(pid, key: key, modifiers: req["modifiers"] as? [String] ?? [])
case "probe": result = opProbe(pid)
default: fail("unknown op \(op)")
}

var payload = result
payload["op"] = op
payload["pid"] = pidValue
jsonOut(payload)
