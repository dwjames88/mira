import CoreImage
import MiraCamera
import MiraCameraKit
import MiraCore
import UIKit
import XCTest
@testable import Mira

/// The main preview shows the photo the right way up. Regression for the staged-grade flip (b94afca): the editor
/// mirrored every photo vertically at zoom 1 while the FILMS cards, rendered another way, were upright. The tests render
/// through `LivePreview.render` into a real CAMetalLayer drawable (what `MetalPreviewView.draw` does), because Core
/// Image writes drawables and plain textures in opposite row orders, and look for a red mark in the photo's top-left
/// and a green one in its top-right.
@MainActor
final class PreviewOrientationTests: XCTestCase {
    static let ink = CIColor(red: 0.082, green: 0.078, blue: 0.059)
    static let drawable = CGSize(width: 1000, height: 1000)

    func model(portrait: Bool, film: Bool, crop: (rect: CropRect, aspectID: String)? = nil) -> EditorViewModel {
        let w = portrait ? 600 : 800, h = portrait ? 800 : 600
        let picture = CIImage(cgImage: DrawableCanvas.markedPicture(width: w, height: h))
        let m = EditorViewModel()
        m.present(LoadedSource(image: picture, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, size: picture.extent.size))
        m.live.proxyBox = Self.drawable
        if film { m.select(StepConsistencyTests.film(mono: false).id) }
        m.recipe.grainAmount = 0
        if let crop {
            m.recipe.crop.rect = crop.rect
            m.recipe.crop.aspect = crop.aspectID
        }
        return m
    }

    func frame(_ m: EditorViewModel, zoom: CGFloat) throws -> DrawableCanvas.Frame {
        try XCTUnwrap(DrawableCanvas.render(m.live, size: Self.drawable, recipe: m.liveRecipe, zoom: zoom,
                                            contentScale: 3, ink: Self.ink))
    }

    func testMarksAreUprightEverywhere() throws {
        for portrait in [true, false] {
            for film in [false, true] {
                for zoom in [CGFloat(1), 2] {
                    let label = "\(portrait ? "portrait" : "landscape") \(film ? "film" : "no film") zoom \(Int(zoom))"
                    DrawableCanvas.assertMarksUpright(try frame(model(portrait: portrait, film: film), zoom: zoom), label)
                }
            }
        }
    }

    /// The crops the camera writes for every aspect, for the angles it reports (90 portrait, 0 and 180 landscape).
    func testCaptureRecipeCropsKeepTheMarksTopLeftAndTopRight() throws {
        let sensor = PixelSize(width: 4032, height: 3024)
        for aspect in CaptureAspect.allCases {
            for angle in [90.0, 0, 180] {
                let portrait = angle == 90
                let crop = CaptureCrop.recipeCrop(sensorSize: sensor, rotationAngle: angle, aspect: aspect)
                if aspect == .fourThree {
                    XCTAssertNil(crop, "a 4:3 capture writes no crop")
                    let m = model(portrait: portrait, film: false)
                    XCTAssertTrue(m.recipe.crop.isIdentity)
                    DrawableCanvas.assertMarksUpright(try frame(m, zoom: 1), "4:3 angle \(Int(angle))")
                    continue
                }
                let c = try XCTUnwrap(crop, "\(aspect) angle \(angle)")
                for film in [false, true] {
                    for zoom in [CGFloat(1), 2] {
                        let m = model(portrait: portrait, film: film, crop: c)
                        DrawableCanvas.assertMarksUpright(try frame(m, zoom: zoom),
                                                          "\(aspect) angle \(Int(angle)) \(film ? "film" : "no film") zoom \(Int(zoom))")
                    }
                }
            }
        }
    }

    /// FILMS cards come out of the engine's own thumbnail render: the same way up as the main preview.
    func testFilmCardThumbnailsAreUpright() async throws {
        for portrait in [true, false] {
            let w = portrait ? 600 : 800, h = portrait ? 800 : 600
            let data = NSMutableData()
            let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, DrawableCanvas.markedPicture(width: w, height: h), [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            let m = EditorViewModel()
            await m.openData(data as Data)
            XCTAssertTrue(m.hasPhoto)
            m.live.proxyBox = Self.drawable
            let colour = StepConsistencyTests.film(mono: false).id
            for id in [nil, colour] {
                await m.requestThumbnail(id)
                let card = try XCTUnwrap(m.thumbnails[id ?? "__original"]?.cgImage, "thumbnail \(String(describing: id))")
                DrawableCanvas.assertMarksUpright(DrawableCanvas.frame(of: card), "\(portrait ? "portrait" : "landscape") card \(id ?? "original")")
            }
            // The main preview of the same photo, opened through the same path, agrees with the card.
            m.select(colour)
            m.recipe.grainAmount = 0
            DrawableCanvas.assertMarksUpright(try frame(m, zoom: 1), "\(portrait ? "portrait" : "landscape") opened data zoom 1")
        }
    }
}
