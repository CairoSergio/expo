// Copyright 2022-present 650 Industries. All rights reserved.

import SDWebImage
import ExpoModulesCore
import VisionKit

typealias SDWebImageContext = [SDWebImageContextOption: Any]

private let imageManager = ImageManager()

// swiftlint:disable:next type_body_length
public final class ImageView: ExpoView {
  static let contextSourceKey = SDWebImageContextOption(rawValue: "source")
  static let screenScaleKey = SDWebImageContextOption(rawValue: "screenScale")

  let sdImageView = SDAnimatedImageView(frame: .zero)

  // Custom image manager doesn't use shared loaders managers by default,
  // so make sure it is provided here.
//  let imageManager = SDWebImageManager(
//    cache: SDImageCache.shared,
//    loader: SDImageLoadersManager.shared
//  )

  var loadingOptions: SDWebImageOptions = [
    .retryFailed, // Don't blacklist URLs that failed downloading
    .handleCookies // Handle cookies stored in the shared `HTTPCookieStore`
  ]

  var sources: [ImageSource]?

  var pendingReloadTask: Task<Void, Error>?

  var pendingOperation: SDWebImageCombinedOperation?

  var contentFit: ContentFit = .cover

  var contentPosition: ContentPosition = .center

  var transition: ImageTransition?

  var blurRadius: CGFloat = 0.0

  var imageTintColor: UIColor = .clear

  var cachePolicy: ImageCachePolicy = .disk

  var recyclingKey: String? {
    didSet {
      if recyclingKey != oldValue {
        sdImageView.image = nil
      }
    }
  }

  // MARK: - Events

  let onLoadStart = EventDispatcher()

  let onProgress = EventDispatcher()

  let onError = EventDispatcher()

  let onLoad = EventDispatcher()

  // MARK: - View

  public override var bounds: CGRect {
    didSet {
      // Reload the image when the bounds size has changed and the view is mounted.
      if oldValue.size != bounds.size && window != nil {
        reload()
      }
    }
  }

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)

    clipsToBounds = true
    sdImageView.contentMode = contentFit.toContentMode()
    sdImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    sdImageView.layer.masksToBounds = false

    // Apply trilinear filtering to smooth out mis-sized images.
    sdImageView.layer.magnificationFilter = .trilinear
    sdImageView.layer.minificationFilter = .trilinear

    addSubview(sdImageView)
  }

  public override func didMoveToWindow() {
    if window == nil {
      // Cancel pending requests when the view is unmounted.
      cancelPendingOperation()
    } else if !bounds.isEmpty {
      // Reload the image after mounting the view with non-empty bounds.
      reload()
    } else {
      loadPlaceholderIfNecessary()
    }
  }

  // MARK: - Implementation

  func reload() {
    log.trace("reload \(loadingOptions.contains(.highPriority) ? "second" : "first")")

    if isViewEmpty {
      displayPlaceholderIfNecessary()
    }
    guard let source = bestSource else {
      displayPlaceholderIfNecessary()
      return
    }
    if sdImageView.image == nil {
      sdImageView.contentMode = contentFit.toContentMode()
    }

    // Cancel previous reload. It may prevent processing the image that is
    // already going to be outdated and overriden by the new image load.
    cancelPendingOperation()

    pendingReloadTask = Task {
      onLoadStart([:])

      let options = ImageLoadOptions(
        cachePolicy: cachePolicy,
        screenScale: screenScale
      )
      let result = await imageManager.loadImage(source: source, options: options)

      guard let image = result.image, !Task.isCancelled else {
        return
      }
      onLoad([
        "cacheType": result.cacheType.rawValue,
        "source": [
          "url": source.uri?.absoluteString,
          "width": image.size.width,
          "height": image.size.height,
          "mediaType": imageFormatToMediaType(image.sd_imageFormat)
        ]
      ])

      let scale = window?.screen.scale ?? UIScreen.main.scale
      let idealSize = idealSize(
        contentPixelSize: image.size * image.scale,
        containerSize: frame.size,
        scale: scale,
        contentFit: contentFit
      ).rounded(.up)

      let processedImage = await processImage(image, idealSize: idealSize, scale: scale)

      // Stop execution if canceled
//      if Task.isCancelled, !isViewEmpty {
//        return
//      }

      applyContentPosition(contentSize: idealSize, containerSize: frame.size)
      renderImage(processedImage)
    }
  }

  // MARK: - Loading

  private func imageLoadProgress(_ receivedSize: Int, _ expectedSize: Int, _ imageUrl: URL?) {
    // Don't send the event when the expected size is unknown (it's usually -1 or 0 when called for the first time).
    if expectedSize <= 0 {
      return
    }

    // Photos library requester emits the progress as a double `0...1` that we map to `0...100` int in `PhotosLoader`.
    // When that loader is used, we don't have any information about the sizes in bytes, so we only send the `progress` param.
    let isPhotoLibraryAsset = isPhotoLibraryAssetUrl(imageUrl)

    onProgress([
      "loaded": isPhotoLibraryAsset ? nil : receivedSize,
      "total": isPhotoLibraryAsset ? nil : expectedSize,
      "progress": Double(receivedSize) / Double(expectedSize)
    ])
  }

  // swiftlint:disable:next function_parameter_count
  private func imageLoadCompleted(
    _ image: UIImage?,
    _ data: Data?,
    _ error: Error?,
    _ cacheType: SDImageCacheType,
    _ finished: Bool,
    _ imageUrl: URL?
  ) {
    if let error = error {
      onError(["error": error.localizedDescription])
      return
    }
    guard finished else {
      log.debug("Loading the image has been canceled")
      return
    }
    if let image = image {
      onLoad([
        "cacheType": cacheTypeToString(cacheType),
        "source": [
          "url": imageUrl?.absoluteString,
          "width": image.size.width,
          "height": image.size.height,
          "mediaType": imageFormatToMediaType(image.sd_imageFormat)
        ]
      ])

      let scale = window?.screen.scale ?? UIScreen.main.scale
      let idealSize = idealSize(
        contentPixelSize: image.size * image.scale,
        containerSize: frame.size,
        scale: scale,
        contentFit: contentFit
      ).rounded(.up)

      Task {
        let processedImage = await processImage(image, idealSize: idealSize, scale: scale)

        applyContentPosition(contentSize: idealSize, containerSize: frame.size)
        renderImage(processedImage)

//        if cacheType != SDImageCacheType.disk {
//          await diskCache.store(key: imageUrl!.absoluteString, data: image.sd_imageData()!)
//        }
      }
    } else {
      displayPlaceholderIfNecessary()
    }
  }

  // MARK: - Placeholder

  /**
   A list of sources that the placeholder can be loaded from.
   */
  var placeholderSources: [ImageSource] = [] {
    didSet {
      loadPlaceholderIfNecessary()
    }
  }

  /**
   A placeholder image to use when the proper image is unset.
   */
  var placeholderImage: UIImage?

  /**
   Content fit for the placeholder. `scale-down` seems to be the best choice for spinners
   and that the placeholders are usually smaller than the proper image, but it doesn't
   apply to blurhash that by default could use the same fitting as the proper image.
   */
  var placeholderContentFit: ContentFit = .scaleDown

  /**
   Same as `bestSource`, but for placeholders.
   */
  var bestPlaceholder: ImageSource? {
    return getBestSource(from: placeholderSources, forSize: bounds.size, scale: screenScale) ?? placeholderSources.first
  }

  /**
   Loads a placeholder from the best source provided in `placeholder` prop.
   A placeholder should be a local asset to have more time to show before the proper image is loaded,
   but remote assets are also supported – for the bundler and to cache them on the disk to load faster next time.
   - Note: Placeholders are not being resized nor transformed, so try to keep them small.
   */
  func loadPlaceholderIfNecessary() {
    // Exit early if placeholder is not set or there is already an image attached to the view.
    // The placeholder is only used until the first image is loaded.
    guard let placeholder = bestPlaceholder, isViewEmpty || !hasAnySource else {
      return
    }
    let isPlaceholderHash = placeholder.isBlurhash || placeholder.isThumbhash

    Task {
      let options = ImageLoadOptions(cachePolicy: .none, screenScale: screenScale)
      let result = await imageManager.loadImage(source: placeholder, options: options)

      guard let placeholder = result.image else {
        return
      }
      placeholderImage = placeholder
      placeholderContentFit = isPlaceholderHash ? contentFit : placeholderContentFit
      displayPlaceholderIfNecessary()
    }
//    var context = SDWebImageContext()
//
//    context[.imageScaleFactor] = placeholder.scale
//    context[.cacheKeyFilter] = createCacheKeyFilter(placeholder.cacheKey)
//
//    // Cache placeholders on the disk. Should we let the user choose whether
//    // to cache them or apply the same policy as with the proper image?
//    // Basically they are also cached in memory as the `placeholderImage` property,
//    // so just `disk` policy sounds like a good idea.
//    context[.queryCacheType] = SDImageCacheType.disk.rawValue
//    context[.storeCacheType] = SDImageCacheType.disk.rawValue
//
//    // Some loaders (e.g. blurhash) need access to the source.
//    context[ImageView.contextSourceKey] = placeholder

//    imageManager.loadImage(with: placeholder.uri, context: context, progress: nil) { [weak self] placeholder, _, _, _, finished, _ in
//      guard let self = self, let placeholder = placeholder, finished else {
//        return
//      }
//      self.placeholderImage = placeholder
//      self.placeholderContentFit = isPlaceholderHash ? self.contentFit : self.placeholderContentFit
//      self.displayPlaceholderIfNecessary()
//    }
  }

  /**
   Displays a placeholder if necessary – the placeholder can only be displayed when no image has been displayed yet or the sources are unset.
   */
  private func displayPlaceholderIfNecessary() {
    guard isViewEmpty || !hasAnySource, let placeholder = placeholderImage else {
      return
    }
    setImage(placeholder, contentFit: placeholderContentFit)
  }

  // MARK: - Processing

  private func createTransformPipeline() -> SDImagePipelineTransformer {
    let transformers: [SDImageTransformer] = [
      SDImageBlurTransformer(radius: blurRadius),
      SDImageTintTransformer(color: imageTintColor)
    ]
    return SDImagePipelineTransformer(transformers: transformers)
  }

  private func processImage(_ image: UIImage?, idealSize: CGSize, scale: Double) async -> UIImage? {
    guard let image = image, !bounds.isEmpty else {
      return nil
    }
    // Downscale the image only when necessary
    if shouldDownscale(image: image, toSize: idealSize, scale: scale) {
      return await resize(animatedImage: image, toSize: idealSize, scale: scale)
    }
    return image
  }

  // MARK: - Rendering

  /**
   Moves the layer on which the image is rendered to respect the `contentPosition` prop.
   */
  private func applyContentPosition(contentSize: CGSize, containerSize: CGSize) {
    let offset = contentPosition.offset(contentSize: contentSize, containerSize: containerSize)
    sdImageView.layer.frame.origin = offset
  }

  private func renderImage(_ image: UIImage?) {
    if let transition = transition, transition.duration > 0 {
      let options = transition.toAnimationOptions()
      let seconds = transition.duration / 1000

      UIView.transition(with: sdImageView, duration: seconds, options: options) { [weak self] in
        if let self = self {
          self.setImage(image, contentFit: self.contentFit)
        }
      }
    } else {
      setImage(image, contentFit: contentFit)
    }
  }

  private func setImage(_ image: UIImage?, contentFit: ContentFit) {
    sdImageView.contentMode = contentFit.toContentMode()
    sdImageView.image = image

    log.warn("set \(loadingOptions.contains(.highPriority) ? "second" : "first") image:", image != nil)

    if enableLiveTextInteraction {
      analyzeImage()
    }
  }

  // MARK: - Helpers

  func cancelPendingOperation() {
    pendingOperation?.cancel()
    pendingOperation = nil
    pendingReloadTask?.cancel()
    pendingReloadTask = nil
  }

  /**
   A scale of the screen where the view is presented,
   or the main scale if the view is not mounted yet.
   */
  var screenScale: Double {
    return window?.screen.scale as? Double ?? UIScreen.main.scale
  }

  /**
   The image source that fits best into the view bounds.
   */
  var bestSource: ImageSource? {
    return getBestSource(from: sources, forSize: bounds.size, scale: screenScale)
  }

  /**
   A bool value whether the image view doesn't render any image.
   */
  var isViewEmpty: Bool {
    return sdImageView.image == nil
  }

  /**
   A bool value whether there is any source to load from.
   */
  var hasAnySource: Bool {
    return sources?.isEmpty == false
  }

  // MARK: - Live Text Interaction

  @available(iOS 16.0, *)
  static let imageAnalyzer = ImageAnalyzer.isSupported ? ImageAnalyzer() : nil

  var enableLiveTextInteraction: Bool = false {
    didSet {
      guard #available(iOS 16.0, *), oldValue != enableLiveTextInteraction, ImageAnalyzer.isSupported else {
        return
      }
      if enableLiveTextInteraction {
        let imageAnalysisInteraction = ImageAnalysisInteraction()
        sdImageView.addInteraction(imageAnalysisInteraction)
      } else if let interaction = findImageAnalysisInteraction() {
        sdImageView.removeInteraction(interaction)
      }
    }
  }

  private func analyzeImage() {
    guard #available(iOS 16.0, *), ImageAnalyzer.isSupported, let image = sdImageView.image else {
      return
    }

    Task {
      guard let imageAnalyzer = Self.imageAnalyzer, let imageAnalysisInteraction = findImageAnalysisInteraction() else {
        return
      }
      let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])

      do {
        let imageAnalysis = try await imageAnalyzer.analyze(image, configuration: configuration)

        // Make sure the image haven't changed in the meantime.
        if image == sdImageView.image {
          imageAnalysisInteraction.analysis = imageAnalysis
          imageAnalysisInteraction.preferredInteractionTypes = .automatic
        }
      } catch {
        log.error(error)
      }
    }
  }

  @available(iOS 16.0, *)
  private func findImageAnalysisInteraction() -> ImageAnalysisInteraction? {
    let interaction = sdImageView.interactions.first {
      return $0 is ImageAnalysisInteraction
    }
    return interaction as? ImageAnalysisInteraction
  }
}
