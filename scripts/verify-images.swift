import AppKit
import Foundation

func run(_ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = arguments
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw NSError(
      domain: "verify-images", code: Int(process.terminationStatus),
      userInfo: [NSLocalizedDescriptionKey: "\(arguments[0]) failed"])
  }
}

func quoted(_ text: String) -> String {
  "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func tapeString(_ text: String) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.withoutEscapingSlashes]
  return String(decoding: try encoder.encode(text), as: UTF8.self)
}

func fixture(_ text: String, at url: URL) throws -> NSImage {
  let image = NSImage(size: NSSize(width: 800, height: 200))
  image.lockFocus()
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: 800, height: 200).fill()
  NSColor.systemTeal.setFill()
  NSRect(x: 20, y: 20, width: 760, height: 20).fill()
  (text as NSString).draw(
    at: NSPoint(x: 35, y: 85),
    withAttributes: [
      .font: NSFont.monospacedSystemFont(ofSize: 36, weight: .bold),
      .foregroundColor: NSColor.black,
    ])
  image.unlockFocus()
  guard let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
  else {
    throw NSError(domain: "verify-images", code: 1)
  }
  try png.write(to: url)
  return image
}

func main() throws {
  let runID = CommandLine.arguments.dropFirst().first ?? "images"
  guard runID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
    fatalError("run-id must contain only letters, digits, dots, underscores, or hyphens")
  }
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let directory = root.appendingPathComponent(".verify/vivi/\(runID)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try run(["zig", "build"])

  let pasteMarker = "VIVI_PASTE_OK_61B4"
  let readMarker = "VIVI_READ_OK_82D9"
  let pasted = try fixture(pasteMarker, at: directory.appendingPathComponent("clipboard.png"))
  let readURL = directory.appendingPathComponent("read.png")
  _ = try fixture(readMarker, at: readURL)
  let pasteboard = NSPasteboard.general
  let saved = (pasteboard.pasteboardItems ?? []).map { item in
    item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
      item.data(forType: type).map { (type, $0) }
    }
  }
  pasteboard.clearContents()
  var changeCount = pasteboard.changeCount
  defer {
    if pasteboard.changeCount == changeCount {
      pasteboard.clearContents()
      let items = saved.map { values in
        let item = NSPasteboardItem()
        for (type, data) in values { item.setData(data, forType: type) }
        return item
      }
      if !items.isEmpty && !pasteboard.writeObjects(items) {
        fputs("Unable to restore clipboard\n", stderr)
      }
    } else {
      fputs("Clipboard changed during verification; leaving the newer contents untouched\n", stderr)
    }
  }
  let wroteClipboard = pasteboard.writeObjects([pasted])
  changeCount = pasteboard.changeCount
  guard wroteClipboard else {
    throw NSError(
      domain: "verify-images", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Unable to set test image clipboard"])
  }

  let log = directory.appendingPathComponent("chat-streaming.terminal.log")
  let gif = directory.appendingPathComponent("chat-streaming.gif")
  let tape = directory.appendingPathComponent("chat-streaming.tape")
  let command =
    "cd \(quoted(root.path)) && script -q \(quoted(log.path)) ./zig-out/bin/vivi chat --model copilot/gpt-5.4-mini"
  let readPrompt =
    "Use the read tool to open \(readURL.path). Reply only with the exact text printed in the image. Do not use bash."
  let tapeContents = """
    Output \(try tapeString(gif.path))
    Set Shell "bash"
    Set FontSize 18
    Set Width 1200
    Set Height 800
    Set TypingSpeed 15ms
    Hide
    Type \(try tapeString(command))
    Enter
    Sleep 8s
    Show
    Sleep 1s
    Ctrl+V
    Sleep 2s
    Type "Reply only with the exact text printed in this image. Do not use tools."
    Enter
    Sleep 25s
    Type \(try tapeString(readPrompt))
    Enter
    Sleep 30s
    PageUp
    Sleep 3s
    PageDown
    Sleep 3s
    Ctrl+C
    Sleep 3s
    Ctrl+C
    Sleep 1s
    """
  try tapeContents.write(to: tape, atomically: true, encoding: .utf8)
  try run(["vhs", tape.path])

  let raw = try String(contentsOf: log, encoding: .utf8)
  let normalized =
    raw
    .replacingOccurrences(
      of: "\\x1b\\][^\\x07]*(?:\\x07|\\x1b\\\\)", with: "", options: .regularExpression
    )
    .replacingOccurrences(of: "\\x1b\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
  try normalized.write(
    to: directory.appendingPathComponent("chat-streaming.normalized.txt"), atomically: true,
    encoding: .utf8)
  let passed = normalized.contains(pasteMarker) && normalized.contains(readMarker)
  try """
  pasted_image_recognized=\(normalized.contains(pasteMarker))
  read_image_recognized=\(normalized.contains(readMarker))
  terminal_graphics_visual_review=required
  """.write(
    to: directory.appendingPathComponent("chat-streaming.assertions.txt"), atomically: true,
    encoding: .utf8)
  guard passed else {
    throw NSError(
      domain: "verify-images", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Image recognition failed; inspect \(directory.path)"])
  }
  guard FileManager.default.fileExists(atPath: gif.path) else {
    throw NSError(
      domain: "verify-images", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Images were recognized, but VHS returned success without a recording. PTY evidence is in \(directory.path)."
      ])
  }
  try run([".github/skills/verify-vivi/bin/verify-vivi", "extract-frames", runID, "chat-streaming"])
  print("Image paste and read recognized. Review extracted frames in \(directory.path).")
}

do {
  try main()
} catch {
  fputs("\(error)\n", stderr)
  exit(1)
}
