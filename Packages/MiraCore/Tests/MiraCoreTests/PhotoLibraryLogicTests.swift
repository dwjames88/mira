import Foundation
import Testing
@testable import MiraCore

@Suite("Photo library logic")
struct PhotoLibraryLogicTests {
    @Test func rawIdentifiers() {
        #expect(RAWDetection.isRAW(typeIdentifier: "com.adobe.raw-image"))
        #expect(RAWDetection.isRAW(typeIdentifier: "public.camera-raw-image"))
        #expect(RAWDetection.isRAW(typeIdentifier: "com.sony.arw-raw-image"))
        #expect(!RAWDetection.isRAW(typeIdentifier: "public.jpeg"))
        #expect(!RAWDetection.isRAW(typeIdentifier: "public.heic"))
        #expect(!RAWDetection.isRAW(typeIdentifier: "not a type"))
        #expect(RAWDetection.containsRAW(["public.jpeg", "com.adobe.raw-image"]))
        #expect(!RAWDetection.containsRAW(["public.jpeg"]))
        #expect(!RAWDetection.containsRAW([]))
    }

    @Test func dirtyCheck() {
        var r = Recipe.neutral
        #expect(!EditDirtyCheck.isDirty(current: r, loaded: .neutral))
        r.grainAmount = 0.4
        #expect(EditDirtyCheck.isDirty(current: r, loaded: .neutral))
        #expect(!EditDirtyCheck.isDirty(current: r, loaded: r))
    }

    @Test func sidecarStatusLines() {
        let image = URL(fileURLWithPath: "/tmp/a/IMG_1.jpg")
        #expect(SidecarStatus.line(location: .adjacent(SidecarStore.sidecarURL(for: image)), imageURL: image)
                == "SIDECAR \u{00B7} IMG_1.jpg.mira.json")
        #expect(SidecarStatus.line(location: .fallback(URL(fileURLWithPath: "/x")), imageURL: image)
                == "SIDECAR \u{00B7} APP SUPPORT (folder not writable)")
        #expect(SidecarStatus.line(location: nil, imageURL: image).contains("IMG_1.jpg.mira.json"))
    }
}
