import UIKit

enum ImageAttachmentHelper {
    static let maxDimension: CGFloat = 1280
    static let jpegQuality: CGFloat = 0.72

    static func prepareJPEGBase64(from image: UIImage) -> String? {
        let scaled = scale(image)
        guard let data = scaled.jpegData(compressionQuality: jpegQuality) else { return nil }
        return data.base64EncodedString()
    }

    static func image(from base64: String) -> UIImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }

    private static func scale(_ image: UIImage) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }
        let ratio = maxDimension / maxSide
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? image
    }
}
