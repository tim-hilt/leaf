# One multiplatform target for iOS, iPadOS and macOS

A single SwiftUI app target serves all Apple platforms, with `#if os(...)` where they differ. This gives a native macOS app (not Mac Catalyst) without duplicating sources or build settings across targets.
