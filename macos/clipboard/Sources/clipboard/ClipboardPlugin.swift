import Cocoa
import FlutterMacOS

public class ClipboardPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var clipboardChangeObserver: NSObjectProtocol?
    private var monitoringTimer: Timer?
    private var lastChangeCount: Int = 0
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "net.cubiclab.clipboard/methods",
            binaryMessenger: registrar.messenger
        )
        let eventChannel = FlutterEventChannel(
            name: "net.cubiclab.clipboard/events",
            binaryMessenger: registrar.messenger
        )
        
        let instance = ClipboardPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general
        
        switch call.method {
        case "copy":
            guard let args = call.arguments as? [String: Any],
                  let text = args["text"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Text is required", details: nil))
                return
            }
            if text.isEmpty {
                result(FlutterError(code: "EMPTY_TEXT", message: "Text cannot be empty", details: nil))
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            result(true)
            
        case "copyRichText":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid arguments", details: nil))
                return
            }
            let text = args["text"] as? String ?? ""
            let html = args["html"] as? String
            
            if text.isEmpty && (html == nil || html!.isEmpty) {
                result(FlutterError(code: "EMPTY_CONTENT", message: "Either text or html must be provided", details: nil))
                return
            }
            
            pasteboard.clearContents()
            if let html = html, !html.isEmpty {
                pasteboard.setString(html, forType: .html)
                if !text.isEmpty {
                    pasteboard.setString(text, forType: .string)
                }
            } else {
                pasteboard.setString(text, forType: .string)
            }
            result(true)
            
        case "copyMultiple":
            guard let args = call.arguments as? [String: Any],
                  let formats = args["formats"] as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid arguments", details: nil))
                return
            }
            if formats.isEmpty {
                result(FlutterError(code: "EMPTY_FORMATS", message: "At least one format must be provided", details: nil))
                return
            }
            
            pasteboard.clearContents()
            
            // Handle image first (highest priority)
            if let imageBytes = formats["image/png"] as? [Int], !imageBytes.isEmpty {
                let data = Data(imageBytes.map { UInt8($0 & 0xFF) })
                if let image = NSImage(data: data) {
                    pasteboard.writeObjects([image])
                    if let text = formats["text/plain"] as? String, !text.isEmpty {
                        pasteboard.setString(text, forType: .string)
                    }
                    result(true)
                    return
                }
            }
            
            // Fallback to HTML or text
            if let text = formats["text/plain"] as? String {
                pasteboard.setString(text, forType: .string)
            }
            if let html = formats["text/html"] as? String {
                pasteboard.setString(html, forType: .html)
            }
            result(true)
            
        case "copyImage":
            guard let args = call.arguments as? [String: Any],
                  let imageBytes = args["imageBytes"] as? [Int] else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Image bytes are required", details: nil))
                return
            }
            if imageBytes.isEmpty {
                result(FlutterError(code: "EMPTY_IMAGE", message: "Image bytes cannot be empty", details: nil))
                return
            }
            let data = Data(imageBytes.map { UInt8($0 & 0xFF) })
            guard let image = NSImage(data: data) else {
                result(FlutterError(code: "INVALID_IMAGE", message: "Failed to decode image", details: nil))
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            result(true)
            
        case "paste":
            let text = pasteboard.string(forType: .string) ?? ""
            result(["text": text])
            
        case "pasteRichText":
            let text = pasteboard.string(forType: .string) ?? ""
            let html = pasteboard.string(forType: .html)
            let imageBytes = getImageBytesFromClipboard()
            result([
                "text": text,
                "html": (html ?? NSNull()) as Any,
                "imageBytes": (imageBytes ?? NSNull()) as Any,
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
            ])
            
        case "pasteImage":
            let imageBytes = getImageBytesFromClipboard()
            if let bytes = imageBytes {
                result(["imageBytes": bytes])
            } else {
                result(["imageBytes": NSNull()])
            }
            
        case "pasteImages":
            // The pasteboard itself is read here, on the thread AppKit expects,
            // but decoding and re-encoding each image is the expensive part and
            // is done off it. Flutter runs macOS with the UI and platform
            // threads merged, so work left on this thread does not merely take
            // time — it freezes the interface for as long as it runs. A single
            // photograph measured a 262ms stall before this.
            let sources = collectImageSources()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let images = self?.encodeImages(sources) ?? []
                DispatchQueue.main.async { result(["images": images]) }
            }

        case "changeCount":
            result(NSPasteboard.general.changeCount)

        case "hasImage":
            // Asks which representations are on the pasteboard without reading
            // any of them, and does it off the main thread.
            //
            // Even the cheap question is not free: on a pasteboard holding a
            // photograph it measured about 50ms, and this is the call made as
            // the attach dialog opens, precisely so that nothing expensive
            // happens then. Flutter runs macOS with the UI and platform threads
            // merged, so 50ms spent here is 50ms of held interface.
            //
            // availableType is a lookup against the pasteboard's type list.
            // canReadObject is a different question — it asks AppKit whether an
            // NSImage could be built, which inspects the data — so it is kept
            // only as the fallback for types that name nothing recognisable.
            DispatchQueue.global(qos: .userInitiated).async {
                let imageTypes: [NSPasteboard.PasteboardType] = [
                    .png, .tiff, .fileURL,
                    NSPasteboard.PasteboardType("public.jpeg"),
                    NSPasteboard.PasteboardType("public.heic"),
                    NSPasteboard.PasteboardType("com.compuserve.gif"),
                    NSPasteboard.PasteboardType("com.microsoft.bmp"),
                ]
                let pasteboard = NSPasteboard.general
                let holds = pasteboard.availableType(from: imageTypes) != nil
                    || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)

                DispatchQueue.main.async { result(holds) }
            }

        case "getContentType":
            // Don't access clipboard automatically
            result("unknown")
            
        case "hasData":
            // Don't access clipboard automatically
            result(false)
            
        case "clear":
            pasteboard.clearContents()
            result(true)
            
        case "getDataSize":
            // Don't access clipboard automatically
            result(0)
            
        case "startMonitoring":
            startMonitoring()
            result(true)
            
        case "stopMonitoring":
            stopMonitoring()
            result(true)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func startMonitoring() {
        if monitoringTimer != nil {
            return
        }
        
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount
        
        // macOS doesn't have native clipboard change notifications
        // Use a timer-based polling approach
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboardChange()
        }
    }
    
    private func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        if let observer = clipboardChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            clipboardChangeObserver = nil
        }
    }
    
    private func checkClipboardChange() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        
        // Only notify if clipboard actually changed
        if currentChangeCount != lastChangeCount {
            lastChangeCount = currentChangeCount
            
            let text = pasteboard.string(forType: .string) ?? ""
            let html = pasteboard.string(forType: .html)
            
            eventSink?([
                "text": text,
                "html": (html ?? NSNull()) as Any,
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
            ])
        }
    }
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        startMonitoring()
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        stopMonitoring()
        return nil
    }
    
    /// The image on the clipboard, as PNG bytes.
    ///
    /// The clipboard describes an image in two quite different ways, and they cannot be
    /// handled the same:
    ///
    /// - copying from inside a graphics app puts the bitmap itself on the pasteboard, under
    ///   `public.png` or `public.tiff`;
    /// - copying a file in Finder puts only a reference to that file.
    ///
    /// The file reference is tried first, because when there is one it names the picture the
    /// user actually chose, and it is read here rather than left to NSImage. Handing a file
    /// reference to `readObjects(forClasses: [NSImage.self])` inside an App Sandbox does not
    /// fail - the sandbox refuses to open the path, and NSImage answers with the file's ICON
    /// instead. That is a perfectly valid image of a document, so nothing anywhere reports an
    /// error, and a picture of a page with "PNG" written on it is pasted in place of the
    /// photograph that was copied.
    ///
    /// Every step falls through to the next rather than giving up, so a file that genuinely
    /// cannot be read still ends up using whatever bitmap the pasteboard also carries.
    /// Every image the pasteboard is carrying, rather than only the first.
    ///
    /// Referenced files come first and are taken as a set - a multi-file copy in
    /// Finder is the usual way several pictures arrive at once. If none of them
    /// can be read, the single-image path is used, so this never returns less
    /// than `getImageBytesFromClipboard` would.
    /// How an image type is named to the user, from a file extension or a
    /// pasteboard type. Nil when it cannot be told, rather than guessed at.
    static func imageTypeName(from identifier: String?) -> String? {
        guard let identifier = identifier?.lowercased() else { return nil }

        switch identifier {
        case "jpg", "jpeg", "public.jpeg": return "JPG"
        case "png", "public.png": return "PNG"
        case "heic", "heif", "public.heic", "public.heif": return "HEIC"
        case "gif", "com.compuserve.gif": return "GIF"
        case "tif", "tiff", "public.tiff": return "TIFF"
        case "bmp", "com.microsoft.bmp": return "BMP"
        case "webp", "org.webmproject.webp": return "WEBP"
        default: return nil
        }
    }

    /// Every image on the pasteboard, each with the type it arrived as.
    ///
    /// The bytes are handed over as PNG whatever they were, so the source type
    /// is reported alongside them rather than left to be inferred from bytes
    /// that no longer carry it.
    /// Where an image on the pasteboard is coming from. Gathered on the main
    /// thread, converted off it.
    private enum ImageSource {
        case file(URL)
        case data(Data, String?)
    }

    /// Names what the pasteboard is holding without converting any of it, which
    /// is the cheap half and the half that has to happen on the main thread.
    private func collectImageSources() -> [ImageSource] {
        let pasteboard = NSPasteboard.general
        var sources: [ImageSource] = []

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["public.image"],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            sources.append(contentsOf: urls.map { ImageSource.file($0) })
        }

        if sources.isEmpty {
            for type in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType.tiff] {
                if let data = pasteboard.data(forType: type) {
                    sources.append(.data(data, ClipboardPlugin.imageTypeName(from: type.rawValue)))
                    break
                }
            }
        }

        return sources
    }

    /// Reads and re-encodes each source. Safe to call off the main thread: it
    /// touches no pasteboard, only the bytes and URLs already gathered from one.
    private func encodeImages(_ sources: [ImageSource]) -> [[String: Any]] {
        var all: [[String: Any]] = []

        for source in sources {
            switch source {
            case .file(let url):
                // A security-scoped bookmark is held against the URL, not the
                // thread, so claiming it here is fine.
                let isScoped = url.startAccessingSecurityScopedResource()
                defer {
                    if isScoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                if let data = try? Data(contentsOf: url), let png = pngData(from: data) {
                    var entry: [String: Any] = ["bytes": png.map { Int($0) }]
                    if let name = ClipboardPlugin.imageTypeName(from: url.pathExtension) {
                        entry["type"] = name
                    }
                    all.append(entry)
                }

            case .data(let data, let type):
                if let png = pngData(from: data) {
                    var entry: [String: Any] = ["bytes": png.map { Int($0) }]
                    if let type = type {
                        entry["type"] = type
                    }
                    all.append(entry)
                }
            }
        }

        return all
    }

    private func getAllImagesFromClipboard() -> [[String: Any]] {
        var all: [[String: Any]] = []

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["public.image"],
        ]
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls {
                let isScoped = url.startAccessingSecurityScopedResource()
                defer {
                    if isScoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                if let data = try? Data(contentsOf: url), let png = pngData(from: data) {
                    var entry: [String: Any] = ["bytes": png.map { Int($0) }]
                    if let name = ClipboardPlugin.imageTypeName(from: url.pathExtension) {
                        entry["type"] = name
                    }
                    all.append(entry)
                }
            }
        }

        if all.isEmpty, let single = getImageBytesFromClipboard() {
            var entry: [String: Any] = ["bytes": single]
            let pasteboard = NSPasteboard.general
            let advertised = pasteboard.types?.map { $0.rawValue } ?? []
            if let name = advertised.compactMap({ ClipboardPlugin.imageTypeName(from: $0) }).first {
                entry["type"] = name
            }
            all.append(entry)
        }

        return all
    }

    private func getImageBytesFromClipboard() -> [Int]? {
        let pasteboard = NSPasteboard.general

        if let bytes = imageBytesFromReferencedFile(pasteboard) {
            return bytes
        }

        // A bitmap already on the pasteboard. No file system involved, so the sandbox has no
        // say in it - this is the path that has always worked.
        for type in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType.tiff] {
            if let data = pasteboard.data(forType: type), let png = pngData(from: data) {
                return png.map { Int($0) }
            }
        }

        // Anything else AppKit can make sense of: the older flavours some apps still write,
        // and images carried inside a PDF or an attachment.
        guard let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let tiffData = image.tiffRepresentation,
              let png = pngData(from: tiffData) else {
            return nil
        }

        return png.map { Int($0) }
    }

    /// The contents of an image file the pasteboard refers to, or nil when it refers to none
    /// that can be read.
    ///
    /// Restricted to file URLs whose contents are images, so copying a document or a folder
    /// falls through to the bitmap flavours rather than being read pointlessly.
    private func imageBytesFromReferencedFile(_ pasteboard: NSPasteboard) -> [Int]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ["public.image"],
        ]

        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }

        for url in urls {
            // A file URL that arrives by paste carries a sandbox extension, but it only
            // grants access once it has been claimed - without this the read below fails for
            // every file outside the container. Balanced whether or not the read succeeds.
            let isScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            if let data = try? Data(contentsOf: url), let png = pngData(from: data) {
                return png.map { Int($0) }
            }
        }

        return nil
    }

    /// Re-encodes anything AppKit can decode as PNG, the one format the Dart side is promised.
    ///
    /// Answers nil for data that is not an image at all, which is what makes it safe to use
    /// as the test of whether a referenced file was worth reading.
    private func pngData(from data: Data) -> Data? {
        guard let bitmapImage = NSBitmapImageRep(data: data) else {
            return nil
        }

        return bitmapImage.representation(using: .png, properties: [:])
    }
    
    deinit {
        stopMonitoring()
    }
}

