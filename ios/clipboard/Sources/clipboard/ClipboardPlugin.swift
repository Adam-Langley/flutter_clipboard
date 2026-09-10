import Flutter
import UIKit

public class ClipboardPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var clipboardChangeObserver: NSObjectProtocol?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "net.cubiclab.clipboard/methods",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "net.cubiclab.clipboard/events",
            binaryMessenger: registrar.messenger()
        )
        
        let instance = ClipboardPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
            UIPasteboard.general.string = text
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
            
            // Use setItems to set both HTML and text together
            // HTML must be Data, text can be String
            // Clear first to ensure clean state
            UIPasteboard.general.items = []
            
            var item: [String: Any] = [:]
            
            if !text.isEmpty {
                item["public.utf8-plain-text"] = text
            }
            if let html = html, !html.isEmpty, let htmlData = html.data(using: .utf8) {
                item["public.html"] = htmlData
            }
            
            if !item.isEmpty {
                UIPasteboard.general.setItems([item], options: [:])
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
            
            // Handle image first (highest priority)
            if let imageBytes = formats["image/png"] as? [Int], !imageBytes.isEmpty {
                let data = Data(imageBytes.map { UInt8($0 & 0xFF) })
                if let image = UIImage(data: data) {
                    UIPasteboard.general.image = image
                    if let text = formats["text/plain"] as? String, !text.isEmpty {
                        UIPasteboard.general.string = text
                    }
                    result(true)
                    return
                }
            }
            
            // Set HTML and text using setItems
            // HTML must be Data, text can be String
            var item: [String: Any] = [:]
            
            if let text = formats["text/plain"] as? String, !text.isEmpty {
                item["public.utf8-plain-text"] = text
            }
            if let html = formats["text/html"] as? String, !html.isEmpty, let htmlData = html.data(using: .utf8) {
                item["public.html"] = htmlData
            }
            
            if !item.isEmpty {
                UIPasteboard.general.setItems([item], options: [:])
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
            guard let image = UIImage(data: data) else {
                result(FlutterError(code: "INVALID_IMAGE", message: "Failed to decode image", details: nil))
                return
            }
            UIPasteboard.general.image = image
            result(true)
            
        case "paste":
            let text = UIPasteboard.general.string ?? ""
            result(["text": text])
            
        case "pasteRichText":
            // Read from items array (most reliable method)
            var text = ""
            var html: String?
            
            if let items = UIPasteboard.general.items as? [[String: Any]], !items.isEmpty {
                let firstItem = items[0]
                
                // Get text (can be String or Data)
                if let textValue = firstItem["public.utf8-plain-text"] as? String {
                    text = textValue
                } else if let textData = firstItem["public.utf8-plain-text"] as? Data,
                          let textString = String(data: textData, encoding: .utf8) {
                    text = textString
                } else {
                    // Fallback to string property
                    text = UIPasteboard.general.string ?? ""
                }
                
                // Get HTML (should be Data when set with setItems)
                if let htmlData = firstItem["public.html"] as? Data,
                   let htmlString = String(data: htmlData, encoding: .utf8) {
                    html = htmlString
                } else if let htmlValue = firstItem["public.html"] as? String {
                    html = htmlValue
                }
            } else {
                // Fallback to convenience properties
                text = UIPasteboard.general.string ?? ""
                if let htmlData = UIPasteboard.general.data(forPasteboardType: "public.html"),
                   let htmlString = String(data: htmlData, encoding: .utf8) {
                    html = htmlString
                }
            }
            
            let imageBytes = getImageBytesFromClipboard()
            result([
                "text": text,
                "html": html ?? NSNull(),
                "imageBytes": imageBytes ?? NSNull(),
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
            // UIPasteboard can hold several items at once - a multi-select in
            // Photos puts one per picture - and `image` only ever answers with
            // the first. Reading them all lets a caller offer the whole set.
            //
            // The bytes are handed over as PNG whatever they arrived as, so the
            // source type is reported separately: it is read from the item's
            // advertised representations, which still name the original.
            //
            // The pasteboard is read here, but each image is re-encoded to PNG
            // off this thread. Flutter can run with the UI and platform threads
            // merged, and work left on this one freezes the interface for as
            // long as it takes rather than merely taking that long.
            let pasteboard = UIPasteboard.general
            let itemTypes = pasteboard.types(forItemSet: nil) ?? []
            let images = pasteboard.images ?? []
            let fallback = images.isEmpty ? pasteboard.image : nil

            DispatchQueue.global(qos: .userInitiated).async {
                var all: [[String: Any]] = []

                for (index, image) in images.enumerated() {
                    guard let data = image.pngData() else { continue }
                    var entry: [String: Any] = ["bytes": Array(data.map { Int($0) })]
                    if index < itemTypes.count, let name = ClipboardPlugin.imageTypeName(from: itemTypes[index]) {
                        entry["type"] = name
                    }
                    all.append(entry)
                }

                // Falls back to whatever single representation the pasteboard
                // would give, for the cases `images` does not surface.
                if all.isEmpty, let data = fallback?.pngData() {
                    var entry: [String: Any] = ["bytes": Array(data.map { Int($0) })]
                    if let name = ClipboardPlugin.imageTypeName(from: itemTypes.first ?? []) {
                        entry["type"] = name
                    }
                    all.append(entry)
                }

                DispatchQueue.main.async { result(["images": all]) }
            }

        case "changeCount":
            // Identifies the pasteboard's current contents. iOS grants read
            // access per generation: once the user has answered the paste
            // banner for this one, reading it again does not ask them twice.
            // A caller that remembers the count it was granted for can tell
            // whether a read would prompt.
            result(UIPasteboard.general.changeCount)

        case "hasImage":
            // UIPasteboard's has* properties report which representations are
            // present without reading them, so they do not raise the paste
            // banner that reading `image` does. That makes it safe to ask on
            // open, which is what lets a caller decide whether to offer a paste
            // affordance at all rather than offering one blindly.
            result(UIPasteboard.general.hasImages)

        case "getContentType":
            // Don't access clipboard automatically - only check if formats are available
            // This avoids triggering iOS clipboard banner on startup
            result("unknown")
            
        case "hasData":
            // Don't access clipboard automatically - return false to avoid triggering iOS clipboard banner
            result(false)
            
        case "clear":
            UIPasteboard.general.string = ""
            result(true)
            
        case "getDataSize":
            // Don't access clipboard automatically - return 0 to avoid triggering iOS clipboard banner
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
        if clipboardChangeObserver != nil {
            return
        }
        
        // iOS doesn't have native clipboard change notifications
        // We'll use a timer-based approach as fallback
        // The Dart side will handle the actual polling
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkClipboardChange()
        }
    }
    
    private func stopMonitoring() {
        if let observer = clipboardChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            clipboardChangeObserver = nil
        }
    }
    
    private func checkClipboardChange() {
        // Only check clipboard when monitoring is active and user has interacted
        // This is called when app becomes active, so it's a user gesture
        let text = UIPasteboard.general.string ?? ""
        var html: String?
        if let htmlData = UIPasteboard.general.data(forPasteboardType: "public.html"),
           let htmlString = String(data: htmlData, encoding: .utf8) {
            html = htmlString
        }
        
        eventSink?([
            "text": text,
            "html": html ?? NSNull(),
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ])
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
    
    /// How an image type is named to the user, from the representations the
    /// pasteboard advertises for one item. Nil when none of them is an image
    /// type this knows, which is treated as "cannot say" rather than guessed at.
    static func imageTypeName(from types: [String]) -> String? {
        let names: [(String, String)] = [
            ("public.jpeg", "JPG"),
            ("public.png", "PNG"),
            ("public.heic", "HEIC"),
            ("public.heif", "HEIC"),
            ("com.compuserve.gif", "GIF"),
            ("public.tiff", "TIFF"),
            ("com.microsoft.bmp", "BMP"),
            ("org.webmproject.webp", "WEBP"),
        ]
        let lowered = types.map { $0.lowercased() }
        for (uti, name) in names where lowered.contains(uti) {
            return name
        }
        return nil
    }

    private func getImageBytesFromClipboard() -> [Int]? {
        guard let image = UIPasteboard.general.image else {
            return nil
        }
        guard let imageData = image.pngData() else {
            return nil
        }
        return Array(imageData.map { Int($0) })
    }
    
    deinit {
        stopMonitoring()
    }
}

