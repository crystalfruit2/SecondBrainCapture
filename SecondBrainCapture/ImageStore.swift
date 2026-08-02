import UIKit

/// Local staging for captured photos.
///
/// A photo is written to disk *before* it is queued, for the same reason text
/// captures are: the capture has to survive a dead connection or the app being
/// killed mid-commit. The file is only deleted once its note has actually
/// landed in the repo.
///
/// Photos are downscaled and JPEG-compressed here, on the phone, before they
/// ever reach the queue. The vault is a git repo synced across two machines and
/// history is forever, so a 12-megapixel original of a whiteboard is a cost
/// that never goes away.
enum ImageStore {
    /// Long edge, in pixels. Comfortably enough to read handwriting back, small
    /// enough that a year of captures doesn't bloat the repo.
    static let maxDimension: CGFloat = 2000
    static let jpegQuality: CGFloat = 0.8

    private static var directory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Normalise a picked photo: downscale to `maxDimension` and bake in the
    /// EXIF orientation.
    ///
    /// Redrawing is what makes the rest of the pipeline simple — the result is
    /// always `.up`, so OCR and the committed JPEG can't disagree about which
    /// way is up. A photo shot in portrait arrives as `.right`, and skipping
    /// this step is the classic way to get sideways text that Vision can't read.
    static func prepared(_ image: UIImage) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > maxDimension ? maxDimension / longEdge : 1
        let target = CGSize(width: (image.size.width * scale).rounded(),
                            height: (image.size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // target is already in pixels
        format.opaque = true      // photos have no alpha; opaque encodes smaller
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func jpegData(for image: UIImage) -> Data? {
        image.jpegData(compressionQuality: jpegQuality)
    }

    /// Persist a prepared image and return its local filename.
    /// The filename matches the note's timestamp so the pair is obvious on disk.
    static func save(_ image: UIImage, date: Date) -> String? {
        guard let data = jpegData(for: image) else { return nil }
        let name = "\(DateFormatter.filenameStamp.string(from: date)).jpg"
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func load(_ filename: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(filename))
    }

    static func delete(_ filename: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }
}
