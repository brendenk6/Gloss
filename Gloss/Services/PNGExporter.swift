import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// CGImage → PNG bytes.
public enum PNGExporter {
    public static func data(from image: CGImage) -> Data? {
        let cf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(cf, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return cf as Data
    }
}
