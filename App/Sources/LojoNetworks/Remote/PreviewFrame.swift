import UIKit

enum PreviewFrame {
    static func jpeg(title: String) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180))
        let image = renderer.image { context in
            UIColor(red: 0.05, green: 0.22, blue: 0.28, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            let captionAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor(white: 1, alpha: 0.8),
            ]
            (title as NSString).draw(in: CGRect(x: 16, y: 64, width: 288, height: 32), withAttributes: titleAttrs)
            ("View-only live screen" as NSString).draw(in: CGRect(x: 16, y: 98, width: 288, height: 20), withAttributes: captionAttrs)
        }
        return image.jpegData(compressionQuality: 0.72) ?? Data()
    }
}
