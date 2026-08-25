import Flutter
import UIKit
import Photos
import Intents
import share_handler_ios_models

public class SwiftShareHandlerIosPlatform: NSObject, FlutterPlugin, FlutterStreamHandler, ShareHandlerApi, FlutterSceneLifeCycleDelegate {

    static let kEventsChannel = "com.shoutsocial.share_handler/sharedMediaStream"

    private var customSchemePrefix = "ShareMedia"

    private var initialMedia: SharedMedia? = nil
    private var latestMedia: SharedMedia? = nil

    private var eventSink: FlutterEventSink? = nil;

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
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    public func hasMatchingSchemePrefix(url: URL?) -> Bool {
        if let url = url, let appDomain = Bundle.main.bundleIdentifier {
            return url.absoluteString.hasPrefix("\(self.customSchemePrefix)-\(appDomain)") || url.absoluteString.hasPrefix("file://")
        }
        return false
    }

    public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [AnyHashable : Any] = [:]) -> Bool {
        if let url = launchOptions[UIApplication.LaunchOptionsKey.url] as? URL {
            if (hasMatchingSchemePrefix(url: url)) {
                return handleUrl(url: url, setInitialData: true)
            }
            return true
        } else if let activityDictionary = launchOptions[UIApplication.LaunchOptionsKey.userActivityDictionary] as? [AnyHashable: Any] {
            for key in activityDictionary.keys {
                if let userActivity = activityDictionary[key] as? NSUserActivity {
                    if let url = userActivity.webpageURL {
                        if (hasMatchingSchemePrefix(url: url)) {
                            return handleUrl(url: url, setInitialData: true)
                        }
                        return true
                    }
                }
            }
        }
        return true
    }

    public func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if (hasMatchingSchemePrefix(url: url)) {
            return handleUrl(url: url, setInitialData: false)
        }
        return false
    }

    public func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([Any]) -> Void) -> Bool {
        if let url = userActivity.webpageURL {
            if (hasMatchingSchemePrefix(url: url)) {
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
        guard let connectionOptions else {
            return false
        }

        for urlContext in connectionOptions.urlContexts where hasMatchingSchemePrefix(url: urlContext.url) {
            if handleUrl(url: urlContext.url, setInitialData: true) {
                return true
            }
        }

        for userActivity in connectionOptions.userActivities {
            if let url = userActivity.webpageURL,
               hasMatchingSchemePrefix(url: url),
               handleUrl(url: url, setInitialData: true) {
                return true
            }
        }

        return false
    }

    public func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) -> Bool {
        for urlContext in urlContexts where hasMatchingSchemePrefix(url: urlContext.url) {
            if handleUrl(url: urlContext.url, setInitialData: false) {
                return true
            }
        }
        return false
    }

    public func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
        guard let url = userActivity.webpageURL, hasMatchingSchemePrefix(url: url) else {
            return false
        }
        return handleUrl(url: url, setInitialData: false)
    }

    private func handleUrl(url: URL?, setInitialData: Bool) -> Bool {
        if let url = url {
            let appGroupId = (Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String) ?? "group.\(Bundle.main.bundleIdentifier!)"
            let userDefaults = UserDefaults(suiteName: appGroupId)

            var sharedMedia: SharedMedia?

            let params = url.queryDictionary
            if let sharedPreferencesKey = params?["key"] {
                if let data = userDefaults?.object(forKey: sharedPreferencesKey) as? Data {
                    sharedMedia = try? JSONDecoder().decode(SharedMedia.self, from: data)
                }
            } else if url.absoluteString.hasPrefix("file://") {
                sharedMedia = SharedMedia.init(attachments: [SharedAttachment.init(path: url.absoluteString, type: SharedAttachmentType.file)], conversationIdentifier: nil, content: nil, speakableGroupName: nil, serviceName: nil, senderIdentifier: nil, imageFilePath: nil)
            }

            if let media = sharedMedia {
                media.attachments?.forEach {$0.path = getAbsolutePath(for: $0.path) ?? $0.path}
                latestMedia = media
                if (setInitialData) {
                    initialMedia = media
                }
                let map = media.toDictionary()
                eventSink?(map)

                return true
            }
        }
        latestMedia = nil
        return false
    }

    private func getAbsolutePath(for identifier: String) -> String? {
        if (identifier.starts(with: "file://") || identifier.starts(with: "/var/mobile/Media") || identifier.starts(with: "/private/var/mobile")) {
            return identifier.replacingOccurrences(of: "file://", with: "")
        }
        let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: .none).firstObject
        if(phAsset == nil) {
            return nil
        }
        let (url, _) = getFullSizeImageURLAndOrientation(for: phAsset!)
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

    func recordSentMessage(_ media: SharedMedia?, error: AutoreleasingUnsafeMutablePointer<FlutterError?>) {
        if let media = media {
            if #available(iOS 14.0, *) {
                let groupName = INSpeakableString(spokenPhrase: media.speakableGroupName ?? "Unknown Contact")
                let sendMessageIntent = INSendMessageIntent(recipients: nil, outgoingMessageType: INOutgoingMessageType.outgoingMessageText, content: nil, speakableGroupName: groupName, conversationIdentifier: media.conversationIdentifier, serviceName: media.serviceName, sender: nil, attachments: nil)

                if let imagePath = media.imageFilePath {
                    let imageUrl = URL(fileURLWithPath: imagePath)
                    let image = INImage.init(url: imageUrl)
                    sendMessageIntent.setImage(image, forParameterNamed: \.speakableGroupName)
                }

                let interaction = INInteraction(intent: sendMessageIntent, response: nil)
                interaction.donate(completion: { err in
                    if err != nil {
                        error.pointee = FlutterError.init(code: "NATIVE_ERR", message: "Error: donating insendmessage intent", details: nil)
                    } else {
                        print("Successfully donated INSendMessageIntent")
                    }
                })
            }
        } else {
            error.pointee = FlutterError.init(code: "NATIVE_ERR", message: "Error: decoding SharedMedia", details: nil)
        }
    }

    public func resetInitialSharedMedia(_ error: AutoreleasingUnsafeMutablePointer<FlutterError?>) {
        initialMedia = nil
    }
}

extension URL {
    var queryDictionary: [String: String]? {
        guard let query = self.query else { return nil}

        var queryStrings = [String: String]()
        for pair in query.components(separatedBy: "&") {

            let key = pair.components(separatedBy: "=")[0]

            let value = pair
                .components(separatedBy:"=")[1]
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? ""

            queryStrings[key] = value
        }
        return queryStrings
    }
}
