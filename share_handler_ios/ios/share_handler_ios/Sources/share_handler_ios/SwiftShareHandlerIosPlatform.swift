import Flutter
import UIKit
import Photos
import Intents
import share_handler_ios_models

public class SwiftShareHandlerIosPlatform: NSObject, FlutterPlugin, FlutterStreamHandler, ShareHandlerApi, FlutterSceneLifeCycleDelegate {

    static let kEventsChannel = "com.shoutsocial.share_handler/sharedMediaStream"

    private var customSchemePrefix = "ShareMedia"
    private let sharedKeyPrefix = "ShareKey-"

    private var initialMedia: SharedMedia? = nil
    private var latestMedia: SharedMedia? = nil
    private var pendingMedia: [SharedMedia] = []
    private let pendingMediaLimit = 16
    private var hasConnectedScene = false

    private var eventSink: FlutterEventSink? = nil

    // Singleton is required for calling functions directly from AppDelegate
    public static let instance = SwiftShareHandlerIosPlatform()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let messenger : FlutterBinaryMessenger = registrar.messenger()
        let api : ShareHandlerApi & NSObjectProtocol = instance
        ShareHandlerApiSetup(messenger, api)

        let eventsChannel = FlutterEventChannel(name: kEventsChannel, binaryMessenger: messenger)
        eventsChannel.setStreamHandler(instance)

        registrar.addApplicationDelegate(instance)
        registrar.addSceneDelegate(instance)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        let queuedMedia = pendingMedia
        pendingMedia.removeAll(keepingCapacity: true)
        queuedMedia.forEach { events($0.toDictionary()) }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    public func hasMatchingScheme(url: URL?) -> Bool {
        guard let url else {
            return false
        }
        if url.isFileURL {
            return true
        }
        guard let appDomain = Bundle.main.bundleIdentifier, !appDomain.isEmpty,
              let scheme = url.scheme,
              let host = url.host,
              host.caseInsensitiveCompare(appDomain) == .orderedSame else {
            return false
        }
        let expectedScheme = "\(customSchemePrefix)-\(appDomain)"
        return scheme.caseInsensitiveCompare(expectedScheme) == .orderedSame
    }

    public func hasMatchingSchemePrefix(url: URL?) -> Bool {
        return hasMatchingScheme(url: url)
    }

    public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [AnyHashable : Any] = [:]) -> Bool {
        if let url = launchOptions[UIApplication.LaunchOptionsKey.url] as? URL {
            if hasMatchingScheme(url: url) {
                _ = handleUrl(url: url, setInitialData: true)
            }
            return true
        } else if let activityDictionary = launchOptions[UIApplication.LaunchOptionsKey.userActivityDictionary] as? [AnyHashable: Any] {
            for case let userActivity as NSUserActivity in activityDictionary.values {
                if let url = userActivity.webpageURL, hasMatchingScheme(url: url) {
                    _ = handleUrl(url: url, setInitialData: true)
                    break
                }
            }
        }
        return true
    }

    public func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if (hasMatchingScheme(url: url)) {
            return handleUrl(url: url, setInitialData: false)
        }
        return false
    }

    public func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([Any]) -> Void) -> Bool {
        if let url = userActivity.webpageURL {
            if (hasMatchingScheme(url: url)) {
                return handleUrl(url: url, setInitialData: false)
            }
        }
        return false
    }

    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions?
    ) -> Bool {
        let setInitialData = !hasConnectedScene
        hasConnectedScene = true

        guard let connectionOptions else {
            return false
        }

        for urlContext in connectionOptions.urlContexts where hasMatchingScheme(url: urlContext.url) {
            if handleUrl(url: urlContext.url, setInitialData: setInitialData) {
                return true
            }
        }

        for userActivity in connectionOptions.userActivities {
            if let url = userActivity.webpageURL,
               hasMatchingScheme(url: url),
               handleUrl(url: url, setInitialData: setInitialData) {
                return true
            }
        }

        return false
    }

    public func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) -> Bool {
        for urlContext in urlContexts where hasMatchingScheme(url: urlContext.url) {
            if handleUrl(url: urlContext.url, setInitialData: false) {
                return true
            }
        }
        return false
    }

    public func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
        guard let url = userActivity.webpageURL, hasMatchingScheme(url: url) else {
            return false
        }
        return handleUrl(url: url, setInitialData: false)
    }

    private func handleUrl(url: URL?, setInitialData: Bool) -> Bool {
        guard let url else {
            latestMedia = nil
            return false
        }

        let sharedMedia: SharedMedia?
        if url.isFileURL {
            sharedMedia = SharedMedia(
                attachments: [SharedAttachment(path: url.absoluteString, type: .file)],
                conversationIdentifier: nil,
                content: nil,
                speakableGroupName: nil,
                serviceName: nil,
                senderIdentifier: nil,
                imageFilePath: nil
            )
        } else {
            guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
                latestMedia = nil
                return false
            }
            let configuredAppGroupId = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String
            let appGroupId = configuredAppGroupId.flatMap { $0.isEmpty ? nil : $0 }
                ?? "group.\(bundleIdentifier)"
            guard !appGroupId.isEmpty,
                  let userDefaults = UserDefaults(suiteName: appGroupId),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let sharedPreferencesKey = components.queryItems?
                    .first(where: { $0.name == "key" })?.value,
                  isValidSharedKey(sharedPreferencesKey) else {
                latestMedia = nil
                return false
            }
            let data = userDefaults.data(forKey: sharedPreferencesKey)
            userDefaults.removeObject(forKey: sharedPreferencesKey)
            guard let data else {
                latestMedia = nil
                return false
            }
            sharedMedia = try? JSONDecoder().decode(SharedMedia.self, from: data)
        }

        if let media = sharedMedia {
            media.attachments?.forEach { $0.path = getAbsolutePath(for: $0.path) ?? $0.path }
            latestMedia = media
            if setInitialData {
                initialMedia = media
            } else {
                emitLiveMedia(media)
            }
            return true
        }
        latestMedia = nil
        return false
    }

    private func isValidSharedKey(_ key: String) -> Bool {
        guard key.hasPrefix(sharedKeyPrefix) else {
            return false
        }
        let uuidString = String(key.dropFirst(sharedKeyPrefix.count))
        return uuidString.count == 36 && UUID(uuidString: uuidString) != nil
    }

    private func emitLiveMedia(_ media: SharedMedia) {
        if let eventSink {
            eventSink(media.toDictionary())
            return
        }
        if pendingMedia.count >= pendingMediaLimit {
            pendingMedia.removeFirst()
        }
        pendingMedia.append(media)
    }

    private func getAbsolutePath(for identifier: String) -> String? {
        if (identifier.starts(with: "file://") || identifier.starts(with: "/var/mobile/Media") || identifier.starts(with: "/private/var/mobile")) {
            return identifier.replacingOccurrences(of: "file://", with: "")
        }
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: .none).firstObject else {
            return nil
        }
        let (url, _) = getFullSizeImageURLAndOrientation(for: phAsset)
        return url
    }

    private func getFullSizeImageURLAndOrientation(for asset: PHAsset)-> (String?, Int) {
        var url: String? = nil
        var orientation: Int = 0
        let semaphore = DispatchSemaphore(value: 0)
        let options2 = PHContentEditingInputRequestOptions()
        options2.isNetworkAccessAllowed = true
        asset.requestContentEditingInput(with: options2){(input, info) in
            orientation = Int(input?.fullSizeImageOrientation ?? 0)
            url = input?.fullSizeImageURL?.path
            semaphore.signal()
        }
        semaphore.wait()
        return (url, orientation)
    }

    func getInitialSharedMedia(_ error: AutoreleasingUnsafeMutablePointer<FlutterError?>) -> SharedMedia? {
        let sharedMedia = initialMedia
        return sharedMedia
    }

    func recordSentMessage(_ media: SharedMedia?, completion: @escaping (FlutterError?) -> Void) {
        guard let media else {
            completion(FlutterError(
                code: "NATIVE_ERR",
                message: "Error: decoding SharedMedia",
                details: nil
            ))
            return
        }

        let groupName = INSpeakableString(spokenPhrase: media.speakableGroupName ?? "Unknown Contact")
        let sendMessageIntent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: nil, speakableGroupName: groupName, conversationIdentifier: media.conversationIdentifier, serviceName: media.serviceName, sender: nil, attachments: nil)

        if let imagePath = media.imageFilePath {
            let imageUrl = URL(fileURLWithPath: imagePath)
            let image = INImage(url: imageUrl)
            sendMessageIntent.setImage(image, forParameterNamed: \.speakableGroupName)
        }

        let interaction = INInteraction(intent: sendMessageIntent, response: nil)
        interaction.donate { error in
            guard let error else {
                completion(nil)
                return
            }
            let nativeError = error as NSError
            completion(FlutterError(
                code: "NATIVE_ERR",
                message: "Error: donating INSendMessageIntent",
                details: [
                    "domain": nativeError.domain,
                    "code": nativeError.code,
                    "message": nativeError.localizedDescription,
                ]
            ))
        }
    }

    public func resetInitialSharedMedia(_ error: AutoreleasingUnsafeMutablePointer<FlutterError?>) {
        initialMedia = nil
    }
}
