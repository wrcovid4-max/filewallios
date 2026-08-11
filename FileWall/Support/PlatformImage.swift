import SwiftUI

// A SwiftUI Image from raw bytes, working on both iOS (UIImage) and macOS
// (NSImage). Images are the one thing we decrypt to memory and never to disk, so
// this init takes Data, not a URL.
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

extension Image {
    init?(vaultData data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        self = Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        self = Image(nsImage: image)
        #else
        return nil
        #endif
    }
}
