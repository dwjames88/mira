import AppKit
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

@MainActor
@Suite("Editor tabs", .serialized)
struct EditorTabTests {
    @Test func startsOnFilms() async throws {
        let model = try await CropModelTests.makeModel()
        #expect(model.tab == .films)
        #expect(!model.isCropping)
        model.cancelWork()
    }

    @Test func enteringCropBeginsItAndLeavingCommits() async throws {
        let model = try await CropModelTests.makeModel()
        model.selectTab(.develop)
        #expect(model.tab == .develop)
        #expect(!model.isCropping)

        model.selectTab(.crop)
        #expect(model.tab == .crop)
        #expect(model.isCropping)
        model.straighten = 5
        model.setAspect("3:2")
        #expect(model.recipe.crop == .identity) // nothing is written until the tab is left

        model.selectTab(.films)
        #expect(model.tab == .films)
        #expect(!model.isCropping)
        #expect(model.recipe.crop.straighten == 5)
        #expect(model.recipe.crop.aspect == "3:2")
        model.cancelWork()
    }

    @Test func doneCommitsAndReturnsToThePreviousTab() async throws {
        let model = try await CropModelTests.makeModel()
        model.selectTab(.develop)
        model.selectTab(.crop)
        model.straighten = -4
        model.commitCrop() // DONE
        #expect(model.tab == .develop)
        #expect(!model.isCropping)
        #expect(model.recipe.crop.straighten == -4)

        // From the default tab: back to films.
        model.selectTab(.films)
        model.selectTab(.crop)
        model.commitCrop()
        #expect(model.tab == .films)
        model.cancelWork()
    }

    @Test func cancelRevertsTheCropAndStaysInTheTab() async throws {
        let model = try await CropModelTests.makeModel()
        model.selectTab(.crop)
        model.straighten = 8
        model.commitCrop()
        #expect(model.recipe.crop.straighten == 8)

        model.selectTab(.crop)
        model.straighten = -10
        model.rotate90()
        model.setAspect("square")
        model.revertCrop() // CANCEL
        #expect(model.tab == .crop)
        #expect(model.isCropping)
        #expect(model.crop == model.recipe.crop)
        #expect(model.recipe.crop.straighten == 8)

        // The tab is still usable: leaving now commits the restored crop unchanged.
        model.selectTab(.develop)
        #expect(model.recipe.crop.straighten == 8)
        #expect(model.recipe.crop.normalizedQuarterTurns == 0)
        model.cancelWork()
    }

    @Test func selectingTheSameTabAndCropWithoutPhotoDoNothing() async throws {
        let model = try await CropModelTests.makeModel()
        model.selectTab(.crop)
        model.straighten = 3
        model.selectTab(.crop)
        #expect(model.isCropping)
        #expect(model.crop.straighten == 3) // not restarted
        model.cancelCrop()
        #expect(model.tab == .films)
        model.cancelWork()

        let empty = EditorModel(library: model.library)
        empty.selectTab(.crop)
        #expect(empty.tab == .films)
        #expect(!empty.isCropping)
    }

    @Test func newSourceClosesTheCropTab() async throws {
        let model = try await CropModelTests.makeModel()
        model.selectTab(.develop)
        model.selectTab(.crop)
        let source = try #require(model.source)
        model.setSource(source)
        #expect(!model.isCropping)
        #expect(model.tab == .develop)
        model.cancelWork()
    }

    @Test func resetAllClearsEverythingButTheSource() async throws {
        let model = try await CropModelTests.makeModel()
        model.recipe.filmID = "fuji-velvia-50"
        model.recipe.exposure = 0.5
        model.recipe.crop.straighten = 4
        #expect(model.canReset && model.canResetAll)
        model.reset()
        #expect(model.recipe.filmID == "fuji-velvia-50")
        #expect(model.recipe.crop.straighten == 4)
        #expect(model.recipe.exposure == 0)
        #expect(!model.canReset)
        model.resetAll()
        #expect(model.recipe == .neutral)
        #expect(model.source != nil)
        model.cancelWork()
    }

    // MARK: Sub-toolbar items

    @Test func extensionModeHidesLibraryAndSave() {
        let items = EditorSubToolbar.Items(host: nil)
        #expect(!items.library && !items.save && !items.status)

        let app = EditorSubToolbar.Items(host: EditorHostBar(
            onLibrary: {}, status: "UNSAVED", save: .init(isEnabled: true, isSaved: false, action: {})))
        #expect(app.library && app.save && app.status)
    }

    // MARK: Share button

    @Test func shareControlExistsInTheAppAndNotInTheExtension() {
        #expect(!EditorSubToolbar.Items(host: nil).share)
        let app = EditorSubToolbar.Items(host: EditorHostBar(
            onLibrary: {}, save: .init(isEnabled: true, isSaved: false, action: {}),
            share: .init(isEnabled: true, action: { _ in })))
        #expect(app.share)
        #expect(!EditorSubToolbar.Items(host: EditorHostBar(onLibrary: {})).share)
    }

    @Test func shareIsEnabledOnlyWithAPhotoAndNothingElseRunning() {
        typealias S = EditorHostBar.Share
        #expect(S.isAvailable(hasPhoto: true, isBusy: false, isCropping: false, isSharing: false))
        #expect(!S.isAvailable(hasPhoto: false, isBusy: false, isCropping: false, isSharing: false))
        #expect(!S.isAvailable(hasPhoto: true, isBusy: true, isCropping: false, isSharing: false))
        #expect(!S.isAvailable(hasPhoto: true, isBusy: false, isCropping: true, isSharing: false))
        #expect(!S.isAvailable(hasPhoto: true, isBusy: false, isCropping: false, isSharing: true))
    }
}
