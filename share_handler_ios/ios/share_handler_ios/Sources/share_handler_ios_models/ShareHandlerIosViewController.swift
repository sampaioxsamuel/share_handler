import UIKit
import Social
import UniformTypeIdentifiers
import Photos
import Intents
import Contacts

@available(iOS 14.0, *)
@available(iOSApplicationExtension 14.0, *)
open class ShareHandlerIosViewController: UIViewController {
    static var hostAppBundleIdentifier = ""
    static var appGroupId = ""
    let sharedKey = "ShareKey"
    var sharedText: [String] = []
    let imageContentType = UTType.image.identifier
    let movieContentType = UTType.movie.identifier
    let textContentType = UTType.text.identifier
    let urlContentType = UTType.url.identifier
    let fileURLType = UTType.fileURL.identifier
    let dataContentType = UTType.data.identifier
    var sharedAttachments: [SharedAttachment] = []
    private var fileNameCounter: [String: Int] = [:]
    private var hasFailed = false
    lazy var userDefaults: UserDefaults? = {
        return UserDefaults(suiteName: ShareHandlerIosViewController.appGroupId)
    }()

    public func loadIds() {
        let shareExtensionAppBundleIdentifier = Bundle.main.bundleIdentifier!
        let lastIndexOfPoint = shareExtensionAppBundleIdentifier.lastIndex(of: ".")
        ShareHandlerIosViewController.hostAppBundleIdentifier = String(shareExtensionAppBundleIdentifier[..<lastIndexOfPoint!])
        ShareHandlerIosViewController.appGroupId = (Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String) ?? "group.\(ShareHandlerIosViewController.hostAppBundleIdentifier)"
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.isHidden = true
        navigationController?.setNavigationBarHidden(true, animated: false)
        loadIds()
        Task {
            await handleInputItems()
        }
    }

    func handleInputItems() async {
        guard let extensionContext else {
            dismissWithError()
            return
        }

        let inputItems = extensionContext.inputItems.compactMap { $0 as? NSExtensionItem }
        guard !inputItems.isEmpty else {
            dismissWithError()
            return
        }
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ShareHandlerIosViewController.appGroupId
        ) != nil else {
            dismissWithError()
            return
        }

        for content in inputItems {
            if let contents = content.attachments {
                for (index, attachment) in (contents).enumerated() {
                    do {
                        if attachment.hasItemConformingToTypeIdentifier(imageContentType) {
                            try await handleImages(content: content, attachment: attachment, index: index)
                        } else if attachment.hasItemConformingToTypeIdentifier(movieContentType) {
                            try await handleVideos(content: content, attachment: attachment, index: index)
                        } else if attachment.hasItemConformingToTypeIdentifier(fileURLType) {
                            try await handleFiles(content: content, attachment: attachment, index: index)
                        } else if attachment.hasItemConformingToTypeIdentifier(urlContentType) {
                            try await handleUrl(content: content, attachment: attachment, index: index)
                        } else if attachment.hasItemConformingToTypeIdentifier(textContentType) {
                            try await handleText(content: content, attachment: attachment, index: index)
                        } else if attachment.hasItemConformingToTypeIdentifier(dataContentType) {
                            try await handleData(content: content, attachment: attachment, index: index)
                        } else {
                            print("Attachment not handled with registered type identifiers: \(attachment.registeredTypeIdentifiers)")
                        }
                        if hasFailed {
                            return
                        }
                    } catch {
                        self.dismissWithError()
                        return
                    }
                }
            }
        }
        let hasMessageIntent = extensionContext.intent is INSendMessageIntent
        guard !sharedAttachments.isEmpty || !sharedText.isEmpty || hasMessageIntent else {
            dismissWithError()
            return
        }
        redirectToHostApp()
    }

    public func getNewFileUrl(fileName: String) -> URL {
        let newFileUrl = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ShareHandlerIosViewController.appGroupId)!
            .appendingPathComponent(fileName)
        return newFileUrl
    }

    public func handleText(content: NSExtensionItem, attachment: NSItemProvider, index: Int) async throws {
        let data = try await attachment.loadItem(forTypeIdentifier: textContentType, options: nil)

        if let item = data as? String {
            sharedText.append(item)
        } else {
            if let d = data as? Data {
                do {
                    let contacts = try CNContactVCardSerialization.contacts(with: d)
                    for contact in contacts {
                        let data = try CNContactVCardSerialization.data(with: [contact])
                        let str = String(data: data, encoding: .utf8)!
                        sharedText.append(str)
                    }
                } catch {
                    dismissWithError()
                }
            } else {
                dismissWithError()
            }
        }
    }

    public func handleUrl(content: NSExtensionItem, attachment: NSItemProvider, index: Int) async throws {
        let data = try await attachment.loadItem(forTypeIdentifier: urlContentType, options: nil)

        if let item = data as? URL {
            sharedText.append(item.absoluteString)
        } else {
            dismissWithError()
        }
    }

    public func handleImages(content: NSExtensionItem, attachment: NSItemProvider, index: Int) async throws {
        let data = try await attachment.loadItem(forTypeIdentifier: imageContentType, options: nil)

        var fileName: String?
        var imageData: Data?
        var sourceUrl: URL?
        if let url = data as? URL {
            fileName = getFileName(from: url, type: .image)
            sourceUrl = url
        } else if let iData = data as? Data {
            fileName = UUID().uuidString + ".png"
            imageData = iData
        } else if let image = data as? UIImage {
            fileName = UUID().uuidString + ".png"
            imageData = image.pngData()
        }

        if let _fileName = fileName {
            let newFileUrl = getNewFileUrl(fileName: _fileName)
            do {
                if FileManager.default.fileExists(atPath: newFileUrl.path) {
                    try FileManager.default.removeItem(at: newFileUrl)
                }
            } catch {
                print("Error removing item")
            }

            var copied: Bool = false
            if let _data = imageData {
                copied = FileManager.default.createFile(atPath: newFileUrl.path, contents: _data)
            } else if let _sourceUrl = sourceUrl {
                copied = copyFile(at: _sourceUrl, to: newFileUrl)
            }

            if (copied) {
                sharedAttachments.append(SharedAttachment.init(path: newFileUrl.absoluteString, type: .image))
            } else {
                dismissWithError()
                return
            }
        } else {
            dismissWithError()
            return
        }
    }

    public func handleVideos(content: NSExtensionItem, attachment: NSItemProvider, index: Int) async throws {
        let data = try await attachment.loadItem(forTypeIdentifier: movieContentType, options: nil)

        if let url = data as? URL {
            let fileName = getFileName(from: url, type: .video)
            let newFileUrl = getNewFileUrl(fileName: fileName)
            let copied = copyFile(at: url, to: newFileUrl)
            if(copied) {
                sharedAttachments.append(SharedAttachment.init(path: newFileUrl.absoluteString, type: .video))
            } else {
                dismissWithError()
            }
        } else {
            dismissWithError()
        }
    }

    public func handleFiles(content: NSExtensionItem, attachment: NSItemProvider, index: Int) async throws {
        let data = try await attachment.loadItem(forTypeIdentifier: fileURLType, options: nil)

        if let url = data as? URL {
            let fileName = getFileName(from: url, type: .file)
            let newFileUrl = getNewFileUrl(fileName: fileName)
            let copied = copyFile(at: url, to: newFileUrl)
            if (copied) {
                sharedAttachments.append(SharedAttachment.init(path: newFileUrl.absoluteString, type: .file))
            } else {
                dismissWithError()
            }
        } else {
            dismissWithError()
        }
    }

    public func handleData(content: NSExtensionItem, attachment: NSItemProvider, index: Int) async throws {
        let data = try await attachment.loadItem(forTypeIdentifier: dataContentType, options: nil)

        if let url = data as? URL {
            let fileName = getFileName(from: url, type: .file)
            let newFileUrl = getNewFileUrl(fileName: fileName)
            let copied = copyFile(at: url, to: newFileUrl)
            if (copied) {
                sharedAttachments.append(SharedAttachment.init(path: newFileUrl.absoluteString, type: .file))
            } else {
                dismissWithError()
            }
        } else {
            dismissWithError()
        }
    }

    public func dismissWithError() {
        guard !hasFailed else {
            return
        }
        hasFailed = true
        print("[ERROR] Error loading data!")
        let error = NSError(
            domain: "com.shoutsocial.share_handler",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Error loading shared data"]
        )
        extensionContext?.cancelRequest(withError: error)
    }

    public func redirectToHostApp() {
        loadIds()
        guard let url = URL(string: "ShareMedia-\(ShareHandlerIosViewController.hostAppBundleIdentifier)://\(ShareHandlerIosViewController.hostAppBundleIdentifier)?key=\(sharedKey)") else {
            dismissWithError()
            return
        }
        var responder = self as UIResponder?
        let selectorOpenURL = sel_registerName("openURL:")

        let intent = self.extensionContext?.intent as? INSendMessageIntent

        let conversationIdentifier = intent?.conversationIdentifier
        let sender = intent?.sender
        let serviceName = intent?.serviceName
        let speakableGroupName = intent?.speakableGroupName

        let sharedMedia = SharedMedia.init(attachments: sharedAttachments, conversationIdentifier: conversationIdentifier, content: sharedText.joined(separator: "\n"), speakableGroupName: speakableGroupName?.spokenPhrase, serviceName: serviceName, senderIdentifier: sender?.contactIdentifier ?? sender?.customIdentifier, imageFilePath: nil)

        let json = sharedMedia.toJson()

        guard let userDefaults else {
            dismissWithError()
            return
        }
        userDefaults.set(json, forKey: sharedKey)
        guard userDefaults.synchronize() else {
            dismissWithError()
            return
        }

        while (responder != nil) {
            if let application = responder as? UIApplication {
                if #available(iOS 18.0, *) {
                    application.open(url, options: [:]) { [weak self] success in
                        if success {
                            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                        } else {
                            self?.dismissWithError()
                        }
                    }
                } else {
                    let _ = application.perform(selectorOpenURL, with: url)
                    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
                return
            }
            responder = responder?.next
        }

        dismissWithError()
    }

    func getExtension(from url: URL, type: SharedAttachmentType) -> String {
        let parts = url.lastPathComponent.components(separatedBy: ".")
        var ex: String? = nil
        if (parts.count > 1) {
            ex = parts.last
        }

        if (ex == nil) {
            switch type {
            case .image:
                ex = "PNG"
            case .video:
                ex = "MP4"
            case .file:
                ex = "TXT"
            default:
                ex = ""
            }
        }
        return ex ?? "Unknown"
    }

    func getFileName(from url: URL, type: SharedAttachmentType) -> String {
        var name = url.lastPathComponent
        if (name.isEmpty) {
            name = UUID().uuidString + "." + getExtension(from: url, type: type)
        }
        if let count = fileNameCounter[name] {
            fileNameCounter[name] = count + 1
            name = "\((name as NSString).deletingPathExtension)_\(count + 1).\((name as NSString).pathExtension)"
        } else {
            fileNameCounter[name] = 1
        }
        return name
    }

    func copyFile(at srcURL: URL, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
        } catch (let error) {
            print("Cannot copy item at \(srcURL) to \(dstURL): \(error)")
            return false
        }
        return true
    }
}
