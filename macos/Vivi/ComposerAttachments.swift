import AppKit
import Foundation
import UniformTypeIdentifiers

let composerAttachmentByteLimit = 20 * 1024 * 1024
let composerAttachmentCountLimit = 32

enum ComposerAttachmentMedia: UInt32, Equatable {
  case png = 1
  case jpeg = 2
  case gif = 3
  case webP = 4

  var label: String {
    switch self {
    case .png: "PNG"
    case .jpeg: "JPEG"
    case .gif: "GIF"
    case .webP: "WebP"
    }
  }

  static func detect(_ data: Data) -> ComposerAttachmentMedia? {
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
      return .png
    }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
      return .jpeg
    }
    if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
      return .gif
    }
    if bytes.count >= 12, bytes[0..<4].elementsEqual(Array("RIFF".utf8)),
      bytes[8..<12].elementsEqual(Array("WEBP".utf8))
    {
      return .webP
    }
    return nil
  }
}

struct ComposerAttachment: Identifiable, Equatable {
  let id: UUID
  let displayName: String
  let media: ComposerAttachmentMedia
  let data: Data

  var sizeLabel: String {
    ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
  }
}

enum ComposerAttachmentAcquisitionError: LocalizedError, Equatable {
  case noImageOnPasteboard
  case unreadable(String)
  case unsupported(String)
  case empty(String)
  case tooLarge(String)
  case tooMany
  case totalTooLarge

  var errorDescription: String? {
    switch self {
    case .noImageOnPasteboard:
      "No image is available on the pasteboard."
    case .unreadable(let name):
      "“\(name)” could not be read."
    case .unsupported(let name):
      "“\(name)” is not a supported PNG, JPEG, GIF, or WebP image."
    case .empty(let name):
      "“\(name)” is empty."
    case .tooLarge(let name):
      "“\(name)” is larger than the 20 MB attachment limit."
    case .tooMany:
      "A message can include at most \(composerAttachmentCountLimit) images."
    case .totalTooLarge:
      "Attachments for one message cannot exceed 20 MB total."
    }
  }
}

@MainActor
protocol ComposerAttachmentAcquiring: AnyObject {
  func chooseImages() async throws -> [ComposerAttachment]
  func pasteImage() throws -> ComposerAttachment
  func cancel()
}

@MainActor
final class AppKitComposerAttachmentAcquirer: ComposerAttachmentAcquiring {
  private var continuation: CheckedContinuation<[URL]?, Never>?
  private var panel: NSOpenPanel?

  func chooseImages() async throws -> [ComposerAttachment] {
    precondition(panel == nil)
    guard let urls = await chooseURLs() else { return [] }
    return try urls.map(Self.snapshot)
  }

  func pasteImage() throws -> ComposerAttachment {
    let pasteboard = NSPasteboard.general
    let png = NSPasteboard.PasteboardType("public.png")
    let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    let gif = NSPasteboard.PasteboardType("com.compuserve.gif")
    let webP = NSPasteboard.PasteboardType("org.webmproject.webp")

    for type in [png, jpeg, gif, webP] {
      if let data = pasteboard.data(forType: type) {
        return try Self.snapshot(data: data, displayName: "Pasted image")
      }
    }
    guard let data = pasteboard.data(forType: .tiff) else {
      throw ComposerAttachmentAcquisitionError.noImageOnPasteboard
    }
    guard data.count <= composerAttachmentByteLimit else {
      throw ComposerAttachmentAcquisitionError.tooLarge("Pasted image")
    }
    guard
      let image = NSImage(data: data),
      let tiff = image.tiffRepresentation,
      let representation = NSBitmapImageRep(data: tiff),
      let pngData = representation.representation(using: .png, properties: [:])
    else {
      throw ComposerAttachmentAcquisitionError.unsupported("Pasted image")
    }
    return try Self.snapshot(data: pngData, displayName: "Pasted image.png")
  }

  func cancel() {
    panel?.close()
    finish(nil)
  }

  static func snapshot(_ url: URL) throws -> ComposerAttachment {
    let name = url.lastPathComponent
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw ComposerAttachmentAcquisitionError.unreadable(name)
    }
    defer { try? handle.close() }
    let data: Data
    do {
      data = try handle.read(upToCount: composerAttachmentByteLimit + 1) ?? Data()
    } catch {
      throw ComposerAttachmentAcquisitionError.unreadable(name)
    }
    return try snapshot(data: data, displayName: name)
  }

  static func snapshot(data: Data, displayName: String) throws -> ComposerAttachment {
    guard !data.isEmpty else {
      throw ComposerAttachmentAcquisitionError.empty(displayName)
    }
    guard data.count <= composerAttachmentByteLimit else {
      throw ComposerAttachmentAcquisitionError.tooLarge(displayName)
    }
    guard let media = ComposerAttachmentMedia.detect(data) else {
      throw ComposerAttachmentAcquisitionError.unsupported(displayName)
    }
    return ComposerAttachment(
      id: UUID(),
      displayName: displayName,
      media: media,
      data: data)
  }

  private func chooseURLs() async -> [URL]? {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      let panel = NSOpenPanel()
      panel.title = "Choose Images"
      panel.message = "Choose PNG, JPEG, GIF, or WebP images to attach."
      panel.prompt = "Attach"
      panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
      panel.canChooseDirectories = false
      panel.canChooseFiles = true
      panel.allowsMultipleSelection = true
      panel.canCreateDirectories = false
      self.panel = panel
      panel.begin { [weak self] response in
        MainActor.assumeIsolated {
          self?.finish(response == .OK ? panel.urls : nil)
        }
      }
    }
  }

  private func finish(_ urls: [URL]?) {
    guard let continuation else { return }
    self.continuation = nil
    panel = nil
    continuation.resume(returning: urls)
  }
}
