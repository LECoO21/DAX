import SwiftUI
import AppKit

struct ImageWorkspaceView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("图片翻译").font(.headline)
                Button("导入图片") { model.importImages(asTranslation: true) }
                Button("重新截图") { model.perform(.imageTranslate) }
                Button("翻译全部") { model.startImageTranslation() }
                Button("取消") { model.cancelImages() }
                Toggle("显示原图", isOn: $model.showOriginalImage)
                Spacer()
                Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }
                Button { NSApp.keyWindow?.performClose(nil) } label: { Image(systemName: "xmark") }
            }
            HSplitView {
                List(model.imageItems, selection: $model.selectedImage) { item in
                    VStack(alignment: .leading) { Text(item.name).lineLimit(1); ImageStateLabel(item: item) }.tag(item.id)
                }.frame(width: 150)
                if let item = model.imageItems.first(where: { $0.id == model.selectedImage }) {
                    ImageDetailView(model: model, item: item)
                } else { Text("导入图片或截图以开始").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }.padding(14).frame(width: 920, height: 620)
    }
}
struct ImageStateLabel: View {
    @ObservedObject var item: ImageItem
    var body: some View { Text(item.state).font(.caption).foregroundStyle(.secondary) }
}
struct ImageDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var item: ImageItem
    @LocalState private var zoom: Double = 1
    var body: some View {
        VStack {
            HStack {
                Text(item.state).foregroundStyle(.secondary)
                if let error = item.error { Text(error).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Slider(value: $zoom, in: 0.5...3).frame(width: 100)
                Button("重试此图") { model.startImageTranslation(only: item.id) }
                Button("导出图片") { model.exportImage(item) }
            }
            ScrollView([.horizontal, .vertical]) {
                let width = 670 * zoom
                let height = width * CGFloat(item.image.height) / CGFloat(item.image.width)
                ZStack(alignment: .topLeading) {
                    Image(decorative: item.image, scale: 1).resizable().frame(width: width, height: height)
                    if !model.showOriginalImage {
                        ForEach(item.lines) { line in
                            if !line.translated.isEmpty {
                                let imageSize = CGSize(width: item.image.width, height: item.image.height)
                                let box = line.overlayBounds(imageSize: imageSize)
                                let scale = width / imageSize.width
                                Text(line.translated).font(.system(size: overlayFontSize(line.translated, size: CGSize(width: box.width * scale - 4, height: box.height * scale - 4))))
                                    .foregroundStyle(.black).padding(2)
                                    .frame(width: max(1, box.width * scale), height: max(1, box.height * scale), alignment: .topLeading)
                                    .background(.white)
                                    .offset(x: box.minX * scale, y: (imageSize.height - box.maxY) * scale)
                            }
                        }
                    }
                }.frame(width: width, height: height)
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(item.lines.indices, id: \.self) { index in
                        HStack(alignment: .top) {
                            TextField("原文", text: Binding(get: { item.lines[index].original }, set: { model.cancelImages(); item.lines[index].original = $0 }), axis: .vertical).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                            TextField("译文", text: Binding(get: { item.lines[index].translated }, set: { model.cancelImages(); item.lines[index].translated = $0 }), axis: .vertical).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                        }
                        Button("重译此区域") { model.retryImageLine(item, lineID: item.lines[index].id) }.controlSize(.small)
                        if let error = item.lines[index].error { Text(error).font(.caption).foregroundStyle(.orange) }
                        Divider()
                    }
                }
            }.frame(maxHeight: 140)
        }.padding(8)
    }
}
