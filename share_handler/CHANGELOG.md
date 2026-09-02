# 0.0.26
Dart - Resolve Android and iOS implementations from the same Git checkout
Android - Safely and asynchronously copy shared content URIs
Android - Fix repeated intents, mixed text/media shares, and plugin lifecycle cleanup
Android - Prevent duplicate initial stream delivery and prune stale attachment cache files
Android - Preserve cold-start versus live-stream routing without waiting for an Activity
Android - Migrate to AGP 9 built-in Kotlin support
iOS - Add UIScene lifecycle support and complete share processing before closing the extension
iOS - Include privacy manifests for App Group UserDefaults in SwiftPM and CocoaPods
iOS - Await message donation, validate callback URLs, and report host opening failures
iOS - Keep initial shares out of the live stream and buffer live events until listening
iOS - Consume share-extension payloads through one-time callback keys
# 0.0.25
Android - Upgrade Android dependencies and tools
# 0.0.23
Android - Starting app from 'recent applications' starts it with the last intent
# 0.0.22
Fix for iOS 18
Fix iOS getFileName function to handle duplicate filenames
Fix iOS UIApplication.openURL is deprecated
# 0.0.21
iOS - Fix for iOS 14 compile error when recording a sent message with INOutgoingMessageType
Android - Add namespace to allow for Gradle 8
# 0.0.20
iOS - Fix for iOS 14 deprecation when recording a sent message with INSendMessageIntent
# 0.0.19
iOS - Don't show default share modal and go straight to redirect to flutter app 
# 0.0.18
Support handling a shared contact card (vcf) on iOS
# 0.0.17
Fix problems receiving files on Android "Android/Files/Recent"
Fix problem with special characters in filename
Update to allow for newer dart sdk version
# 0.0.16
Fix for non public methods in inherited viewcontroller for iOS
# 0.0.15
Updated Readme for custom group id for the runner target
# 0.0.14
Updated readme to comment out custom group id in info plists by default.
# 0.0.13
Setup podspecs and dependencies better for ios
# 0.0.12
Put inheritable view controller into sub pod library so the ShareViewController can simply inherit it, rather than copy in code. Adjusted README accordingly.
# 0.0.11
Fix for receiving shared .txt files on Android
# 0.0.10
Update example to use the latest README instructions
# 0.0.9
Fix for sharing file from safari. Updated readme accordingly.
# 0.0.8
Fixes and updates for README
# 0.0.7
Fixes and updates for README
# 0.0.6
Fix to decode file paths in case of platform encoded paths
Added documentation to model attributes
# 0.0.5
Added support for handling airdropped files
# 0.0.4
Fix for channel sometimes receiving full SharedMedia object rather than map
# 0.0.3
Fix for error getting initial media
# 0.0.2
Initial release of this plugin.
