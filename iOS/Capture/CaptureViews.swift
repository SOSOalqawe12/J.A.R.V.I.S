import SwiftUI
import UIKit
import VisionKit

/// Apple's document camera (edge detection, perspective correction).
struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    @MainActor static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onFinish: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}

/// Simple "take a photo" camera sheet.
struct CameraPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

/// Saves scanned pages as a PDF (+ OCR text) in Scans/ and attaches it to the chat.
@MainActor
enum ScanSaver {
    static func save(_ images: [UIImage], into chat: ChatViewModel) async {
        guard !images.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let base = "Scans/Scan \(formatter.string(from: Date()))"
        let workspace = Workspace.shared
        let pages = images.map { downscaled($0, maxPixel: 1800) }
        do {
            let pdfData = makePDF(pages)
            let pdfURL = try workspace.destination(for: base + ".pdf", overwrite: false)
            try pdfData.write(to: pdfURL)
            var files = [workspace.relativePath(of: pdfURL)]

            let cgImages = pages.compactMap(\.cgImage)
            let text = await Task.detached(priority: .userInitiated) {
                cgImages.map { (try? OCR.recognize($0)) ?? "" }.joined(separator: "\n\n— — —\n\n")
            }.value
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let textURL = try workspace.destination(for: base + ".txt", overwrite: false)
                try text.write(to: textURL, atomically: true, encoding: .utf8)
                files.append(workspace.relativePath(of: textURL))
            }
            chat.noteCreatedFiles(files)
            chat.attach(data: pdfData, name: pdfURL.lastPathComponent, mimeType: "application/pdf")
            if chat.draft.isEmpty {
                chat.draft = "I scanned \(images.count) page\(images.count == 1 ? "" : "s") (saved as \(files[0])). "
            }
            Haptics.success()
        } catch {
            chat.draft = "The scan couldn't be saved: \(error.localizedDescription)"
        }
    }

    static func downscaled(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > maxPixel else { return image }
        let factor = maxPixel / longest
        let size = CGSize(width: image.size.width * image.scale * factor, height: image.size.height * image.scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func makePDF(_ images: [UIImage]) -> Data {
        let pageWidth: CGFloat = 612
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: 792))
        return renderer.pdfData { context in
            for image in images {
                let height = pageWidth * image.size.height / max(image.size.width, 1)
                let rect = CGRect(x: 0, y: 0, width: pageWidth, height: height)
                context.beginPage(withBounds: rect, pageInfo: [:])
                image.draw(in: rect)
            }
        }
    }
}
