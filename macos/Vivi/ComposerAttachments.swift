import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ViviBackend

let composerAttachmentByteLimit = Int(VIVI_BACKEND_ATTACHMENT_MAX_BYTES)
let composerAttachmentCountLimit = Int(VIVI_BACKEND_ATTACHMENT_MAX_COUNT)
let composerAttachmentDecodedPixelLimit = 16 * 1024 * 1024

enum ComposerAttachmentMedia: UInt32, Equatable, Sendable {
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

struct ComposerAttachment: Identifiable, Equatable, @unchecked Sendable {
  let id: UUID
  let displayName: String
  let media: ComposerAttachmentMedia
  let data: Data
  let preview: CGImage?

  init(
    id: UUID,
    displayName: String,
    media: ComposerAttachmentMedia,
    data: Data,
    preview: CGImage? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.media = media
    self.data = data
    self.preview = preview
  }

  var sizeLabel: String {
    ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
  }

  static func == (lhs: ComposerAttachment, rhs: ComposerAttachment) -> Bool {
    lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.media == rhs.media
      && lhs.data == rhs.data
  }
}

enum ComposerAttachmentAcquisitionError: LocalizedError, Equatable, Sendable {
  case noImageOnPasteboard
  case unreadable(String)
  case unsupported(String)
  case empty(String)
  case tooLarge(String)
  case tooMany
  case totalTooLarge
  case dimensionsTooLarge

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
    case .dimensionsTooLarge:
      "The pasted image dimensions are too large to attach safely."
    }
  }
}

@MainActor
protocol ComposerAttachmentAcquiring: AnyObject {
  func chooseImages() async throws -> [ComposerAttachment]
  func pasteImage() async throws -> ComposerAttachment
  func cancel()
}

@MainActor
final class AppKitComposerAttachmentAcquirer: ComposerAttachmentAcquiring {
  typealias FileSnapshotter =
    @Sendable ([URL]) throws -> [ComposerAttachment]

  private var continuation: CheckedContinuation<[URL]?, Never>?
  private var panel: NSOpenPanel?
  private var fileSnapshotTask: Task<[ComposerAttachment], Error>?
  private var pasteSnapshotTask: Task<ComposerAttachment, Error>?
  private let fileSnapshotter: FileSnapshotter

  init(
    fileSnapshotter: @escaping FileSnapshotter = {
      try AppKitComposerAttachmentAcquirer.snapshots($0)
    }
  ) {
    self.fileSnapshotter = fileSnapshotter
  }

  func chooseImages() async throws -> [ComposerAttachment] {
    precondition(panel == nil)
    guard let urls = await chooseURLs() else { return [] }
    return try await snapshotFiles(urls)
  }

  func pasteImage() async throws -> ComposerAttachment {
    let pasteboard = NSPasteboard.general
    let png = NSPasteboard.PasteboardType("public.png")
    let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    let gif = NSPasteboard.PasteboardType("com.compuserve.gif")
    let webP = NSPasteboard.PasteboardType("org.webmproject.webp")

    for type in [png, jpeg, gif, webP] {
      if let data = pasteboard.data(forType: type) {
        return try await runPasteSnapshot {
          try Self.snapshot(data: data, displayName: "Pasted image")
        }
      }
    }
    guard let data = pasteboard.data(forType: .tiff) else {
      throw ComposerAttachmentAcquisitionError.noImageOnPasteboard
    }
    guard data.count <= composerAttachmentByteLimit else {
      throw ComposerAttachmentAcquisitionError.tooLarge("Pasted image")
    }
    return try await runPasteSnapshot {
      try Self.snapshotTIFF(data)
    }
  }

  func cancel() {
    panel?.close()
    fileSnapshotTask?.cancel()
    pasteSnapshotTask?.cancel()
    finish(nil)
  }

  nonisolated static func snapshot(_ url: URL) throws -> ComposerAttachment {
    try Task.checkCancellation()
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
      data = try readBounded(handle)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ComposerAttachmentAcquisitionError.unreadable(name)
    }
    try Task.checkCancellation()
    return try snapshot(data: data, displayName: name)
  }

  nonisolated static func readBounded(_ handle: FileHandle) throws -> Data {
    var data = Data()
    while data.count <= composerAttachmentByteLimit {
      try Task.checkCancellation()
      let remaining = composerAttachmentByteLimit + 1 - data.count
      guard
        let chunk = try handle.read(upToCount: min(64 * 1024, remaining)),
        !chunk.isEmpty
      else { break }
      data.append(chunk)
    }
    return data
  }

  nonisolated static func snapshots(_ urls: [URL]) throws -> [ComposerAttachment] {
    guard urls.count <= composerAttachmentCountLimit else {
      throw ComposerAttachmentAcquisitionError.tooMany
    }
    var attachments: [ComposerAttachment] = []
    attachments.reserveCapacity(urls.count)
    var totalBytes = 0
    for url in urls {
      try Task.checkCancellation()
      let attachment = try snapshot(url)
      totalBytes += attachment.data.count
      guard totalBytes <= composerAttachmentByteLimit else {
        throw ComposerAttachmentAcquisitionError.totalTooLarge
      }
      attachments.append(attachment)
    }
    return attachments
  }

  nonisolated static func snapshot(
    data: Data,
    displayName: String
  ) throws -> ComposerAttachment {
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
      data: data,
      preview: preview(data))
  }

  nonisolated static func preview(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: 72,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  nonisolated static func snapshotTIFF(_ data: Data) throws -> ComposerAttachment {
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw ComposerAttachmentAcquisitionError.unsupported("Pasted image")
    }
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else {
      throw ComposerAttachmentAcquisitionError.unsupported("Pasted image")
    }
    try validateDecodedDimensions(width: width, height: height)
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw ComposerAttachmentAcquisitionError.unsupported("Pasted image")
    }
    try Task.checkCancellation()
    let encoded = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        encoded,
        UTType.png.identifier as CFString,
        1,
        nil)
    else {
      throw ComposerAttachmentAcquisitionError.unsupported("Pasted image")
    }
    CGImageDestinationAddImage(destination, image, nil)
    try Task.checkCancellation()
    guard CGImageDestinationFinalize(destination) else {
      throw ComposerAttachmentAcquisitionError.unsupported("Pasted image")
    }
    return try snapshot(
      data: encoded as Data,
      displayName: "Pasted image.png")
  }

  nonisolated static func validateDecodedDimensions(width: Int, height: Int) throws {
    guard width > 0, height > 0,
      width <= composerAttachmentDecodedPixelLimit / height
    else {
      throw ComposerAttachmentAcquisitionError.dimensionsTooLarge
    }
  }

  func snapshotFiles(_ urls: [URL]) async throws -> [ComposerAttachment] {
    precondition(fileSnapshotTask == nil)
    let snapshotter = fileSnapshotter
    let task = Task.detached {
      try Task.checkCancellation()
      let attachments = try snapshotter(urls)
      try Task.checkCancellation()
      return attachments
    }
    fileSnapshotTask = task
    defer { fileSnapshotTask = nil }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func runPasteSnapshot(
    _ operation: @escaping @Sendable () throws -> ComposerAttachment
  ) async throws -> ComposerAttachment {
    precondition(pasteSnapshotTask == nil)
    let task = Task.detached {
      try Task.checkCancellation()
      let attachment = try operation()
      try Task.checkCancellation()
      return attachment
    }
    pasteSnapshotTask = task
    defer { pasteSnapshotTask = nil }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
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
