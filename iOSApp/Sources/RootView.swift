import MiraCore
import MiraUI
import PhotosUI
import SwiftUI

enum EditorTab: Hashable { case films, develop, crop }

struct RootView: View {
    @State private var model = EditorViewModel()
    @State private var tab: EditorTab = .films
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                FFHairline()
                canvas
                FFHairline()
                FFTabBar([(value: EditorTab.films, title: "FILMS"),
                          (value: .develop, title: "DEVELOP"),
                          (value: .crop, title: "CROP")], selection: $tab)
                FFHairline()
                controls
            }
        }
        .foregroundStyle(FieldFramesTheme.paper)
        .tint(FieldFramesTheme.lichen)
        .onChange(of: tab) { old, new in
            if new == .crop { model.beginCrop() }
            else if old == .crop { model.commitCrop() }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await model.pick(item) }
        }
    }

    private var header: some View {
        HStack {
            Text("Mira").font(FieldFramesTheme.display(30, weight: .regular))
            Spacer()
            PhotosPicker(selection: $pickerItem, matching: .images) {
                ChooseLabel()
            }
        }
        .padding(.horizontal, FieldFramesTheme.cells(2))
        .padding(.vertical, FieldFramesTheme.rows(0.5))
    }

    @ViewBuilder private var canvas: some View {
        Group {
            if let image = model.previewImage {
                Image(uiImage: image).resizable().scaledToFit()
                    .overlay { if model.isCropping { CropOverlayView(model: model) } }
                    .padding(FieldFramesTheme.cells(1))
            } else {
                FFEmptyState(title: "Mira", subtitle: "CHOOSE A PHOTO TO BEGIN")
                    .overlay(alignment: .bottom) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Text("CHOOSE PHOTO")
                        }
                        .buttonStyle(.ffProminent)
                        .padding(.bottom, FieldFramesTheme.rows(2))
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var controls: some View {
        switch tab {
        case .films: FilmsPanel(model: model)
        case .develop: DevelopPanel(model: model)
        case .crop: CropTab(model: model)
        }
    }
}

struct FilmsPanel: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        VStack(spacing: FieldFramesTheme.rows(1)) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: FieldFramesTheme.cells(1)) {
                    FilmCard(title: "Original", caption: "NO LOOK", image: model.thumbnails["__original"],
                             isSelected: model.filmID == nil) { model.select(nil) }
                    ForEach(PhotoEngine.filmList) { film in
                        FilmCard(title: film.displayName, caption: "\(film.brand.uppercased()) · ISO \(film.iso)",
                                 image: model.thumbnails[film.id], isSelected: model.filmID == film.id) {
                            model.select(film.id)
                        }
                    }
                }
                .padding(.horizontal, FieldFramesTheme.cells(2))
            }
            FFSlider("STRENGTH", value: $model.strength, in: 0...1, default: 1)
                .padding(.horizontal, FieldFramesTheme.cells(2))
                .disabled(model.filmID == nil)
            HStack {
                Text(model.status).ffLabel(size: 10).lineLimit(2)
                Spacer()
                Button(model.isSaving ? "SAVING" : "SAVE") { Task { await model.save() } }
                    .buttonStyle(.ffProminent)
                    .disabled(!model.hasPhoto || model.isSaving)
            }
            .padding(.horizontal, FieldFramesTheme.cells(2))
        }
        .padding(.vertical, FieldFramesTheme.rows(1))
    }
}

struct ChooseLabel: View {
    var body: some View { Text("CHOOSE").ffLabel(size: 11) }
}
