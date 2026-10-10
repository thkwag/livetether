// Opens every window of the LUMIX Webcam app in each language and reports text cut short with an
// ellipsis, content that scrolls, and windows taller than the screen.
//
// The app is started once per language with -AppleLanguages. The setup guide opens by itself while
// the camera extension is not installed; the settings window is opened from the menu bar menu and
// each tab is shown in turn. Every window is captured, and its texts and scroll areas are read
// through the accessibility interface. After the app quits, text recognition reads each text's
// area of the capture: a text is cut short when far fewer characters show than it holds, or when
// a line ends in an ellipsis.
//
// The app's windows come to the front for about ten seconds per language. The terminal running
// the check needs the Accessibility and Screen Recording permissions. Quit LUMIX Webcam first.
//
// With --screenshots, each window is also saved with its shadow, and the menu bar menu as well, as
// <directory>/<language>-<window>.png.
//
// Usage: swift scripts/check-window-layout.swift <LUMIX Webcam.app> [--screenshots <directory>] [language ...]
// Exit status 0 means no window had a finding.

import AppKit
import ApplicationServices
import Foundation
import Vision

let appURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "")
var screenshots: URL?
var requestedLanguages: [String] = []
var argumentIndex = 2
while argumentIndex < CommandLine.arguments.count {
    let argument = CommandLine.arguments[argumentIndex]
    if argument == "--screenshots", argumentIndex + 1 < CommandLine.arguments.count {
        screenshots = URL(fileURLWithPath: CommandLine.arguments[argumentIndex + 1], isDirectory: true)
        argumentIndex += 2
    } else {
        requestedLanguages.append(argument)
        argumentIndex += 1
    }
}
let languages = requestedLanguages.isEmpty ? ["en", "ko", "ja"] : requestedLanguages
let captures = FileManager.default.temporaryDirectory.appendingPathComponent("lumix-window-layout-\(getpid())")
let recognitionLanguages = ["en": "en-US", "ko": "ko-KR", "ja": "ja-JP"]

var findings: [String] = []

/// One captured window: the picture, where the window was, and the texts accessibility reported in it.
struct WindowSample {
    let place: String
    let language: String
    let image: URL
    let frame: CGRect
    let texts: [(value: String, frame: CGRect)]
    let anchors: [String]
}

var samples: [WindowSample] = []

func wait(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

// MARK: - Accessibility

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func role(_ element: AXUIElement) -> String {
    attribute(element, kAXRoleAttribute) as? String ?? ""
}

func title(_ element: AXUIElement) -> String {
    attribute(element, kAXTitleAttribute) as? String ?? ""
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
        return nil
    }
    var point = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: point, size: extent)
}

func descendants(_ element: AXUIElement, where matches: (AXUIElement) -> Bool) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var queue = [element]
    while !queue.isEmpty {
        let next = queue.removeFirst()
        if matches(next) { found.append(next) }
        queue.append(contentsOf: children(next))
    }
    return found
}

func windows(of app: AXUIElement) -> [AXUIElement] {
    attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
}

func waitForWindow(of app: AXUIElement, titled wanted: String, timeout: TimeInterval) -> AXUIElement? {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if let window = windows(of: app).first(where: { title($0) == wanted }) {
            return window
        }
        wait(0.2)
    }
    return nil
}

func waitForMenuBarItem(of app: AXUIElement, timeout: TimeInterval) -> AXUIElement? {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if let extras = attribute(app, "AXExtrasMenuBar"), CFGetTypeID(extras) == AXUIElementGetTypeID(),
           let item = children(extras as! AXUIElement).first {
            return item
        }
        wait(0.2)
    }
    return nil
}

// MARK: - Strings

/// The app's string table for one language, to find windows, menu items and tabs by their titles.
func strings(_ language: String) -> [String: String] {
    let url = appURL.appendingPathComponent("Contents/Resources/\(language).lproj/Localizable.strings")
    guard let data = try? Data(contentsOf: url),
          let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
        return [:]
    }
    return table
}

func squeezed(_ text: String) -> String {
    text.filter { !$0.isWhitespace }
}

// MARK: - Capture and checks

func windowNumber(pid: pid_t, frame wanted: CGRect) -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for entry in list where (entry[kCGWindowOwnerPID as String] as? pid_t) == pid {
        guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
              let number = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
        let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        if abs(rect.minX - wanted.minX) < 2, abs(rect.minY - wanted.minY) < 2, abs(rect.width - wanted.width) < 2, abs(rect.height - wanted.height) < 2 {
            return number
        }
    }
    return nil
}

/// Captures one window by its number; `shadow` keeps the window's shadow, as a screenshot shows it.
func capture(window number: CGWindowID, to file: URL, shadow: Bool) throws {
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x"] + (shadow ? [] : ["-o"]) + ["-l\(number)", file.path]
    try capture.run()
    capture.waitUntilExit()
}

func recognizedLines(in image: CGImage, language: String) -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = [recognitionLanguages[language] ?? "en-US", "en-US"]
    do {
        try VNImageRequestHandler(cgImage: image).perform([request])
    } catch {
        return []
    }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

func enlarged(_ image: CGImage, by factor: Int) -> CGImage {
    guard let context = CGContext(
        data: nil, width: image.width * factor, height: image.height * factor, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * factor, height: image.height * factor))
    return context.makeImage() ?? image
}

/// Text recognition reads an ellipsis as "…", "..." or a run of dots such as "•··".
func endsInEllipsis(_ line: String) -> Bool {
    let dots: Set<Character> = [".", "…", "·", "•", "∙", "⋅", "・", "･", "⋯"]
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.contains("…") || trimmed.reversed().prefix(while: { dots.contains($0) }).count >= 2
}

/// Captures one window and records its texts; scroll areas and the window height are judged here,
/// the texts after the app quits. `anchors` are texts the window must show, so a capture or a
/// recognition that read nothing cannot pass as a clean window.
func check(window: AXUIElement, pid: pid_t, name: String, language: String, anchors: [String]) {
    let place = "[\(language)] \(name)"
    guard let windowFrame = frame(window) else {
        findings.append("\(place): no window frame")
        return
    }

    // A scroll area scrolls when its scroll bar's knob is shorter than the bar, or, with no bar
    // exposed, when its content is taller than the area.
    for area in descendants(window, where: { role($0) == kAXScrollAreaRole }) {
        guard let areaFrame = frame(area) else { continue }
        if let bar = attribute(area, kAXVerticalScrollBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() {
            let barElement = bar as! AXUIElement
            let track = frame(barElement)?.height ?? 0
            let knob = children(barElement).filter { role($0) == kAXValueIndicatorRole }.compactMap(frame).first?.height ?? track
            if knob < track - 1 {
                findings.append("\(place): content scrolls; the scroll bar's knob is \(Int(knob)) pt of \(Int(track)) pt")
            }
        } else if let size = attribute(area, "AXContentSize"), CFGetTypeID(size) == AXValueGetTypeID() {
            var content = CGSize.zero
            AXValueGetValue(size as! AXValue, .cgSize, &content)
            if content.height > areaFrame.height + 1 {
                findings.append("\(place): content scrolls; \(Int(content.height)) pt of content in \(Int(areaFrame.height)) pt")
            }
        }
    }
    if let screen = NSScreen.main, windowFrame.height > screen.visibleFrame.height {
        findings.append("\(place): window is \(Int(windowFrame.height)) pt tall; the screen shows \(Int(screen.visibleFrame.height)) pt")
    }

    guard let number = windowNumber(pid: pid, frame: windowFrame) else {
        findings.append("\(place): window not found for capture")
        return
    }
    let image = captures.appendingPathComponent("\(language)-\(name).png")
    do {
        try capture(window: number, to: image, shadow: false)
        if let directory = screenshots {
            try capture(window: number, to: directory.appendingPathComponent("\(language)-\(name).png"), shadow: true)
        }
    } catch {
        findings.append("\(place): capture failed: \(error)")
        return
    }
    let texts = descendants(window, where: { role($0) == kAXStaticTextRole }).compactMap { element -> (String, CGRect)? in
        guard let value = attribute(element, kAXValueAttribute) as? String, !value.isEmpty, let textFrame = frame(element) else { return nil }
        return (value, textFrame)
    }
    samples.append(WindowSample(place: place, language: language, image: image, frame: windowFrame, texts: texts, anchors: anchors))
    print("\(place): captured, \(texts.count) texts, \(Int(windowFrame.width)) × \(Int(windowFrame.height)) pt")
}

/// Reads the captures: every text must show nearly all of its characters, and no line may end in an ellipsis.
func analyze(_ sample: WindowSample) {
    guard let source = CGImageSourceCreateWithURL(sample.image as CFURL, nil),
          let captured = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        findings.append("\(sample.place): capture cannot be read")
        return
    }
    // A window on a display without Retina scaling is captured at one pixel per point, where text
    // recognition misreads small text; read such captures enlarged to two pixels per point.
    let picture = Double(captured.width) < sample.frame.width * 1.5 ? enlarged(captured, by: 2) : captured
    let scale = CGFloat(picture.width) / sample.frame.width
    let whole = recognizedLines(in: picture, language: sample.language)
    let wholeText = squeezed(whole.joined())
    for anchor in sample.anchors where !wholeText.contains(squeezed(anchor)) {
        findings.append("\(sample.place): \"\(anchor)\" was not read; see \(sample.image.path)")
    }
    for line in whole where endsInEllipsis(line) {
        findings.append("\(sample.place): line ends in an ellipsis: \"\(line)\"")
    }
    for text in sample.texts {
        let full = squeezed(text.value).count
        guard full >= 10 else { continue }
        let area = CGRect(
            x: (text.frame.minX - sample.frame.minX) * scale,
            y: (text.frame.minY - sample.frame.minY) * scale,
            width: text.frame.width * scale,
            height: text.frame.height * scale
        ).insetBy(dx: -4, dy: -4).intersection(CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        guard !area.isNull, let crop = picture.cropping(to: area) else { continue }
        let lines = recognizedLines(in: crop, language: sample.language)
        let shown = squeezed(lines.joined()).count
        if Double(shown) < Double(full) * 0.85 || lines.contains(where: endsInEllipsis) {
            findings.append("\(sample.place): text cut short, \(shown) of \(full) characters show: \"\(text.value)\"")
        }
    }
    print("\(sample.place): \(whole.count) lines and \(sample.texts.count) texts read")
}

// MARK: - Run

func run(language: String) {
    let table = strings(language)
    func localized(_ key: String) -> String { table[key] ?? key }

    let process = Process()
    process.executableURL = appURL.appendingPathComponent("Contents/MacOS/LUMIX Webcam")
    process.arguments = ["-AppleLanguages", "(\(language))"]
    do {
        try process.run()
    } catch {
        findings.append("[\(language)] cannot start the app: \(error)")
        return
    }
    defer {
        process.terminate()
        process.waitUntilExit()
    }
    let app = AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1.5)

    guard waitForMenuBarItem(of: app, timeout: 15) != nil else {
        findings.append("[\(language)] menu bar item not found")
        return
    }
    // The guide opens by itself only while a setup step remains; otherwise open it from the menu.
    var guide = waitForWindow(of: app, titled: localized("LUMIX Webcam Setup"), timeout: 3)
    if guide == nil, let item = waitForMenuBarItem(of: app, timeout: 1) {
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        wait(0.5)
        if let entry = descendants(item, where: { role($0) == kAXMenuItemRole && title($0) == localized("Setup Guide…") }).first {
            AXUIElementPerformAction(entry, kAXPressAction as CFString)
        }
        guide = waitForWindow(of: app, titled: localized("LUMIX Webcam Setup"), timeout: 5)
    }
    if let guide {
        wait(0.8)
        check(window: guide, pid: process.processIdentifier, name: "setup-guide", language: language,
              anchors: [localized("Set Up LUMIX Webcam")])
    } else {
        findings.append("[\(language)] setup guide did not open")
    }

    guard let item = waitForMenuBarItem(of: app, timeout: 1) else {
        findings.append("[\(language)] menu bar item not found")
        return
    }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    wait(0.5)
    if let directory = screenshots {
        // The open menu is the app's only window above the normal window level.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let menu = list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == process.processIdentifier && (($0[kCGWindowLayer as String] as? Int) ?? 0) > 0 }
        if let number = menu?[kCGWindowNumber as String] as? CGWindowID {
            try? capture(window: number, to: directory.appendingPathComponent("\(language)-menu.png"), shadow: true)
        }
    }
    let settingsTitle = localized("Settings…")
    guard let menuItem = descendants(item, where: { role($0) == kAXMenuItemRole && title($0) == settingsTitle }).first else {
        findings.append("[\(language)] menu item \"\(settingsTitle)\" not found")
        return
    }
    AXUIElementPerformAction(menuItem, kAXPressAction as CFString)

    let tabs: [(key: String, name: String, anchor: String)] = [
        ("General", "settings-general", "Camera Extension"),
        ("Camera", "settings-camera", "Live View"),
        ("Advanced", "settings-advanced", "USB Product IDs"),
    ]
    // The settings window opens on the tab shown last, and its title is that tab's name.
    let tabTitles = Set(tabs.map { localized($0.key) })
    var settingsWindow: AXUIElement?
    let deadline = Date(timeIntervalSinceNow: 10)
    while settingsWindow == nil, Date() < deadline {
        settingsWindow = windows(of: app).first { tabTitles.contains(title($0)) }
        if settingsWindow == nil { wait(0.2) }
    }
    guard let settings = settingsWindow else {
        findings.append("[\(language)] settings window did not open; windows: \(windows(of: app).map(title))")
        return
    }
    for tab in tabs {
        if let button = descendants(settings, where: { title($0) == localized(tab.key) && role($0) != kAXWindowRole }).first {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
        guard let window = waitForWindow(of: app, titled: localized(tab.key), timeout: 5) else {
            findings.append("[\(language)] \(tab.name) did not open")
            continue
        }
        wait(0.8)
        check(window: window, pid: process.processIdentifier, name: tab.name, language: language,
              anchors: [localized(tab.anchor)])
    }
}

guard FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/MacOS/LUMIX Webcam").path) else {
    print("usage: swift scripts/check-window-layout.swift <LUMIX Webcam.app> [language ...]")
    exit(2)
}
guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
    print("This check needs the Accessibility and Screen Recording permissions for this terminal.")
    exit(2)
}
try? FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
if let directory = screenshots {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
for language in languages {
    run(language: language)
}
for sample in samples {
    analyze(sample)
}
for finding in findings {
    print("finding: \(finding)")
}
print("\(samples.count) windows checked in \(languages.joined(separator: ", ")); \(findings.count) findings; captures in \(captures.path)")
exit(findings.isEmpty && !samples.isEmpty ? 0 : 1)
