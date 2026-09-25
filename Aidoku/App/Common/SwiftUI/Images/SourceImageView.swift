//
//  SourceImageView.swift
//  Aidoku
//
//  Created by Skitty on 4/26/25.
//

import AidokuRunner
import Nuke
import NukeUI
import SwiftUI

struct SourceImageView: View {
    var source: AidokuRunner.Source?

    let imageUrl: String
    var width: CGFloat?
    var height: CGFloat?
    var downsampleWidth: CGFloat?
    var contentMode: ContentMode = .fill
    var placeholder = "MangaPlaceholder"

    @State private var imageRequest: ImageRequest?
    @State private var loadedRequestIdentity: [String]?

    private var requestIdentity: [String] { [source?.key ?? "", imageUrl] }

    // History covers and local files need no source callback. Supply their
    // request on the first body evaluation so a memory hit needs no extra task.
    var resolvedImageRequest: ImageRequest? {
        let url = URL(string: imageUrl)
        if let fileUrl = url?.toAidokuFileUrl() {
            return ImageRequest(url: fileUrl)
        }
        if source == nil || url?.isFileURL == true {
            return ImageRequest(url: url)
        }
        return loadedRequestIdentity == requestIdentity ? imageRequest : nil
    }

    private var processors: [ImageProcessing] {
        CoverImageProcessing.processors(source: source, downsampleWidth: downsampleWidth)
    }

    var body: some View {
        LazyImage(
            request: resolvedImageRequest,
            transaction: .init(animation: .default)
        ) { state in
            if state.imageContainer?.type == .gif, let data = state.imageContainer?.data {
                GIFImage(
                    data: data,
                    contentMode: contentMode
                )
                    .frame(width: width, height: height)
                    .id(state.image != nil ? imageUrl : "placeholder") // ensures only opacity is animated
            } else {
                let result = if let image = state.image {
                    image
                } else {
                    Image(placeholder)
                }
                result
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(width: width, height: height)
                    .id(state.image != nil ? imageUrl : "placeholder") // ensures only opacity is animated
            }
        }
        .processors(processors)
        .task(id: requestIdentity) {
            guard source != nil, let url = URL(string: imageUrl),
                  !url.isFileURL, url.toAidokuFileUrl() == nil else { return }
            imageRequest = nil
            loadedRequestIdentity = nil
            await loadImageRequest(url: imageUrl)
        }
    }

    func loadImageRequest(url: String) async {
        let url = URL(string: url)
        if let fileUrl = url?.toAidokuFileUrl() {
            imageRequest = ImageRequest(url: fileUrl)
            return
        }
        guard let source, let url, !url.isFileURL else {
            imageRequest = ImageRequest(url: url)
            return
        }
        let request = await source.getModifiedImageRequest(url: url, context: nil)
        guard !Task.isCancelled else { return }
        imageRequest = ImageRequest(
            urlRequest: request,
            userInfo: [.processesKey: source.features.processesCovers]
        )
        loadedRequestIdentity = requestIdentity
    }
}
