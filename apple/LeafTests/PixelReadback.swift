#if os(iOS)
    import Testing
    import UIKit

    @testable import Leaf

    /// Reads back what a view shows on screen, as pixels.
    @MainActor protocol PixelReadback {}

    extension PixelReadback {
        /// Waits for PDFKit to finish drawing the pages: it draws them again,
        /// sharper, after first showing them.
        func settle() async throws { try await Task.sleep(for: .seconds(1.5)) }

        /// Expects `color` on screen at `point`, within two seconds.
        func expectShown(_ color: RGB, at point: CGPoint, in view: UIView) async throws {
            var shown = pixel(at: point, in: view)
            for _ in 0..<40 where !shown.isClose(to: color) {
                try await Task.sleep(for: .milliseconds(50))
                shown = pixel(at: point, in: view)
            }
            #expect(shown.isClose(to: color), "\(shown) at \(point)")
        }

        /// Expects `color` on screen at `point` from now on, for half a second.
        func expectAlwaysShown(_ color: RGB, at point: CGPoint, in view: UIView) async throws {
            for _ in 0..<25 {
                let shown = pixel(at: point, in: view)
                #expect(shown.isClose(to: color), "\(shown) at \(point)")
                guard shown.isClose(to: color) else { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func pixel(at point: CGPoint, in view: UIView) -> RGB { pixels(at: [point], in: view)[0] }

        /// What `view` shows at each point, all from the same moment.
        func pixels(at points: [CGPoint], in view: UIView) -> [RGB] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            let cg = image.cgImage!
            let (width, height) = (CGFloat(cg.width), CGFloat(cg.height))
            return points.map { point in
                var bytes = [UInt8](repeating: 0, count: 4)
                let context = CGContext(
                    data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(x: -point.x, y: point.y - height + 1, width: width, height: height))
                return RGB(Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
            }
        }
    }

    /// Windows of the views under test, which a view only holds weakly.
    @MainActor var windows: [UIWindow] = []

    extension RGB {
        func isClose(to other: RGB) -> Bool {
            abs(r - other.r) < 0.05 && abs(g - other.g) < 0.05 && abs(b - other.b) < 0.05
        }
    }
#endif
