//
//  QRCodeDetector.swift
//  contextgo
//
//  Utility for detecting QR codes from images
//

import UIKit
import CoreImage

class QRCodeDetector {
    /// Detect QR code from an image
    /// - Parameter image: The UIImage to scan
    /// - Returns: The decoded string if a QR code is found, nil otherwise
    static func detectQRCode(from image: UIImage) -> String? {
        guard let ciImage = CIImage(image: image) else {
            print("❌ Failed to create CIImage from UIImage")
            return nil
        }

        let context = CIContext()
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )

        guard let detector = detector else {
            print("❌ Failed to create QR code detector")
            return nil
        }

        let features = detector.features(in: ciImage)

        guard let qrFeature = features.first as? CIQRCodeFeature,
              let messageString = qrFeature.messageString else {
            print("❌ No QR code found in image")
            return nil
        }

        print("✅ QR code detected: \(messageString)")
        return messageString
    }
}
