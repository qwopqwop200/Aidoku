// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

import Foundation
import Combine

/// A publisher that starts a new `ImageTask` when a subscriber is added.
///
/// If the requested image is available in the memory cache, the value is
/// delivered immediately. When the subscription is cancelled, the task also
/// gets cancelled.
///
/// - note: In case the pipeline has `isProgressiveDecodingEnabled` option enabled
/// and the image being downloaded supports progressive decoding, the publisher
/// might emit more than a single value.
struct ImagePublisher: Publisher, Sendable {
    typealias Output = ImageResponse
    typealias Failure = ImagePipeline.Error

    let request: ImageRequest
    let pipeline: ImagePipeline

    func receive<S>(subscriber: S) where S: Subscriber, S: Sendable, Failure == S.Failure, Output == S.Input {
        let subscription = ImageSubscription(
            request: self.request,
            pipeline: self.pipeline,
            subscriber: subscriber
        )
        subscriber.receive(subscription: subscription)
    }
}

private final class ImageSubscription<S>: Subscription, Sendable where S: Subscriber, S: Sendable, S.Input == ImageResponse, S.Failure == ImagePipeline.Error {
    private struct State {
        var task: ImageTask?
        var subscriber: S?
        var isStarted = false
    }
    private let state: Mutex<State>
    private let request: ImageRequest
    private let pipeline: ImagePipeline

    init(request: ImageRequest, pipeline: ImagePipeline, subscriber: S) {
        self.pipeline = pipeline
        self.request = request
        self.state = Mutex(value: State(subscriber: subscriber))
    }

    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else { return }
        let subscriber = state.withLock { state -> S? in
            guard !state.isStarted, let subscriber = state.subscriber else { return nil }
            state.isStarted = true
            return subscriber
        }
        guard let subscriber else { return }

        if let image = pipeline.cache[request] {
            _ = subscriber.receive(ImageResponse(container: image, request: request, cacheType: .memory))

            if !image.isPreview {
                finish(.finished)
                return
            }
        }

        guard state.value.subscriber != nil else { return }
        let task = pipeline.loadImage(
             with: request,
             progress: { [weak self] response, _, _ in
                 if let response, let subscriber = self?.state.value.subscriber {
                    // Send progressively decoded image (if enabled and if any)
                     _ = subscriber.receive(response)
                 }
             },
             completion: { [weak self] result in
                 guard let self, let subscriber = self.state.value.subscriber else { return }
                 switch result {
                 case let .success(response):
                    _ = subscriber.receive(response)
                    self.finish(.finished)
                 case let .failure(error):
                     self.finish(.failure(error))
                 }
             }
         )
        let shouldCancel = state.withLock { state in
            guard state.subscriber != nil else { return true }
            state.task = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let (task, subscriber) = state.withLock { state in
            let task = state.task
            let subscriber = state.subscriber
            state.task = nil
            state.subscriber = nil
            return (task, subscriber)
        }
        // Downstream deinit may cancel its subscription. Release it outside
        // the state lock so that reentrant cancellation cannot deadlock.
        withExtendedLifetime(subscriber) { task?.cancel() }
    }

    private func finish(_ completion: Subscribers.Completion<ImagePipeline.Error>) {
        let subscriber = state.withLock { state in
            let subscriber = state.subscriber
            state.subscriber = nil
            state.task = nil
            return subscriber
        }
        subscriber?.receive(completion: completion)
    }
}
