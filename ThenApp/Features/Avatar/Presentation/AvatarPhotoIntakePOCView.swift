#if DEBUG
import ImageIO
import PhotosUI
import SwiftUI

struct AvatarPhotoIntakePOCView: View {
  @Bindable var model: AvatarPhotoIntakeViewModel
  let picker: SystemAvatarPhotoPicker
  let previewLoader: AvatarPhotoPreviewLoader

  @State private var confirmedAdultSelf = false
  @State private var selection: PhotosPickerItem?
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      ZStack {
        Color(.systemBackground).ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            brand
            content
          }
          .frame(maxWidth: 560, alignment: .leading)
          .padding(.horizontal, 24)
          .padding(.vertical, 20)
        }
      }
      .navigationBarHidden(true)
      .accessibilityHidden(scenePhase != .active)
      .overlay {
        if scenePhase != .active {
          ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Label("照片预览已隐藏", systemImage: "lock.shield")
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
    .onChange(of: selection) { _, item in
      guard let item else { return }
      model.prepare {
        try await picker.load(item, confirmedAdultSelf: true)
      }
      selection = nil
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase != .active else { return }
      selection = nil
      confirmedAdultSelf = false
      model.sceneBecameInactive()
    }
    .onDisappear {
      selection = nil
      confirmedAdultSelf = false
      model.sceneBecameInactive()
    }
  }

  private var brand: some View {
    HStack(spacing: 10) {
      Image("BrandMark")
        .resizable()
        .scaledToFit()
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
      Text("于是")
        .font(.title2.weight(.semibold))
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var content: some View {
    switch model.state {
    case .disclosure:
      disclosure
    case .awaitingSelection:
      selectionPanel
    case .importing, .sanitizing, .analyzing:
      processing
    case .review(let photo, let assessment):
      review(photo: photo, assessment: assessment)
    case .replacement(let assessment):
      resultPanel(
        title: "换一张全身照",
        reason: assessment.primaryReason,
        symbol: "person.crop.rectangle.badge.exclamationmark"
      )
    case .unsupported(let assessment):
      resultPanel(
        title: "这张照片暂时无法使用",
        reason: assessment.primaryReason,
        symbol: "photo.badge.exclamationmark"
      )
    case .recoverableFailure(let reason):
      resultPanel(
        title: "照片处理没有完成",
        reason: reason,
        symbol: "arrow.clockwise.circle"
      )
    case .templateFallback:
      templateFallback
    }
  }

  private var disclosure: some View {
    VStack(alignment: .leading, spacing: 24) {
      hero(
        title: "用一张照片试试数字形象",
        subtitle: "照片完全可选。这个内部测试只检查画面是否适合后续处理，不判断身材、尺码或真实合身度。",
        symbol: "person.crop.rectangle"
      )
      VStack(alignment: .leading, spacing: 14) {
        disclosureRow("仅选择一张本人全身照", symbol: "photo.on.rectangle.angled")
        disclosureRow("只在本机临时处理", symbol: "iphone.and.arrow.forward")
        disclosureRow("退出、取消或改用模板时清理", symbol: "trash.slash")
      }

      Toggle("我是照片中的本人且已年满 18 周岁", isOn: $confirmedAdultSelf)
        .font(.body.weight(.medium))
        .toggleStyle(.switch)
        .accessibilityIdentifier("avatar.photo.poc.declaration")

      Button("继续选择照片") { model.continueToPhotoSelection() }
        .buttonStyle(PrimaryPOCButtonStyle())
        .disabled(!confirmedAdultSelf)
        .accessibilityIdentifier("avatar.photo.poc.continue")

      templateButton
    }
  }

  private var selectionPanel: some View {
    VStack(alignment: .leading, spacing: 24) {
      hero(
        title: "选择一张本人全身照",
        subtitle: "尽量让人物从头到脚完整可见，画面中不要出现其他人。系统只会交付你主动选择的这一张。",
        symbol: "photo.on.rectangle"
      )
      photoPicker(replacing: false)
      Button("返回说明") {
        confirmedAdultSelf = false
        model.returnToDisclosure()
      }
      .buttonStyle(SecondaryPOCButtonStyle())
      .accessibilityIdentifier("avatar.photo.poc.return-disclosure")
      templateButton
    }
  }

  private var processing: some View {
    VStack(alignment: .leading, spacing: 24) {
      hero(
        title: processingTitle,
        subtitle: "原始选择不会用于展示。完成后只显示重新编码的净化预览。",
        symbol: "wand.and.sparkles"
      )
      ProgressView()
        .controlSize(.large)
        .accessibilityLabel(processingTitle)
        .accessibilityIdentifier("avatar.photo.poc.processing")
      Button("取消处理") { model.cancelProcessing() }
        .buttonStyle(SecondaryPOCButtonStyle())
        .accessibilityIdentifier("avatar.photo.poc.cancel")
    }
  }

  private func review(
    photo: SanitizedAvatarPhotoHandle,
    assessment: AvatarPhotoQualityAssessment
  ) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("净化预览已准备")
        .font(.largeTitle.bold())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("avatar.photo.poc.review")
      SanitizedAvatarPhotoPreview(
        photo: photo,
        loader: previewLoader
      )
      Text("这张图仅用于当前测试会话，不代表人物形象已经生成。")
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if assessment.primaryReason == .qualityWarning {
        reasonText(.qualityWarning)
      }
      photoPicker(replacing: true)
      templateButton
    }
  }

  private func resultPanel(
    title: LocalizedStringKey,
    reason: AvatarPhotoQualityReason?,
    symbol: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      hero(
        title: title,
        subtitle: "可以重新选择，或直接使用不需要照片的风格化形象。",
        symbol: symbol
      )
      if let reason { reasonText(reason) }
      photoPicker(replacing: true)
      templateButton
    }
  }

  private var templateFallback: some View {
    VStack(alignment: .leading, spacing: 24) {
      hero(
        title: "已改用风格化形象",
        subtitle: "无需上传或选择照片，也可以继续使用内置人物和服装完成穿搭。",
        symbol: "person.crop.square"
      )
      Button("重新开始照片测试") {
        confirmedAdultSelf = false
        model.returnToDisclosure()
      }
      .buttonStyle(SecondaryPOCButtonStyle())
      .accessibilityIdentifier("avatar.photo.poc.restart")
    }
  }

  private func hero(
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey,
    symbol: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: symbol)
        .font(.system(size: 44, weight: .regular))
        .frame(width: 72, height: 72)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityHidden(true)
      Text(title)
        .font(.largeTitle.bold())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      Text(subtitle)
        .font(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func disclosureRow(_ title: LocalizedStringKey, symbol: String) -> some View {
    Label(title, systemImage: symbol)
      .font(.body)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private func photoPicker(replacing: Bool) -> some View {
    PhotosPicker(selection: $selection, matching: .images) {
      if replacing {
        Label("换一张照片", systemImage: "photo.badge.plus")
          .frame(maxWidth: .infinity, minHeight: 44)
      } else {
        Label("从照片中选择", systemImage: "photo.badge.plus")
          .frame(maxWidth: .infinity, minHeight: 44)
      }
    }
    .buttonStyle(PrimaryPOCButtonStyle())
    .accessibilityIdentifier("avatar.photo.poc.picker")
  }

  private var templateButton: some View {
    Button("使用风格化形象") { model.useTemplate() }
      .buttonStyle(SecondaryPOCButtonStyle())
      .accessibilityIdentifier("avatar.photo.poc.template")
  }

  private func reasonText(_ reason: AvatarPhotoQualityReason) -> some View {
    Text(reason.userMessage)
      .font(.body.weight(.medium))
      .fixedSize(horizontal: false, vertical: true)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
      .accessibilityIdentifier("avatar.photo.poc.reason")
  }

  private var processingTitle: LocalizedStringKey {
    switch model.state {
    case .importing: "正在安全导入照片…"
    case .sanitizing: "正在移除照片元数据…"
    case .analyzing: "正在检查画面质量…"
    default: "正在处理照片…"
    }
  }
}

private struct SanitizedAvatarPhotoPreview: View {
  let photo: SanitizedAvatarPhotoHandle
  let loader: AvatarPhotoPreviewLoader

  @State private var image: Image?

  var body: some View {
    ZStack {
      Color(.secondarySystemBackground)
      if let image {
        image
          .resizable()
          .scaledToFit()
          .accessibilityLabel("净化后的照片预览")
      } else {
        ProgressView("正在显示净化预览…")
      }
    }
    .frame(maxWidth: .infinity)
    .aspectRatio(3 / 4, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 24))
    .accessibilityIdentifier("avatar.photo.poc.preview")
    .task(id: photo) {
      image = nil
      guard let data = try? await loader.load(photo),
            !Task.isCancelled,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return }
      image = Image(decorative: cgImage, scale: 1, orientation: .up)
    }
    .onDisappear { image = nil }
  }
}

private struct PrimaryPOCButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .foregroundStyle(isEnabled ? Color(.systemBackground) : Color.primary)
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(
        isEnabled
          ? Color.primary.opacity(configuration.isPressed ? 0.72 : 1)
          : Color(.secondarySystemBackground)
      )
      .clipShape(Capsule())
  }
}

private struct SecondaryPOCButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .foregroundStyle(Color.primary)
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(Color(.secondarySystemBackground).opacity(configuration.isPressed ? 0.72 : 1))
      .clipShape(Capsule())
  }
}

private extension AvatarPhotoQualityReason {
  var userMessage: LocalizedStringKey {
    switch self {
    case .unsupportedFormat: "请选择 JPEG、PNG 或 HEIC 照片。"
    case .unsafeOrCorruptInput: "照片文件无法安全读取，请换一张。"
    case .resourceLimitExceeded: "照片过大，无法在本机安全处理。"
    case .multiplePeople: "画面中出现了多个人，请选择只有你本人的照片。"
    case .noPersonDetected: "没有找到完整人物，请选择清晰的本人全身照。"
    case .personNotFullyVisible: "人物没有从头到脚完整出现在画面中。"
    case .personObscured: "人物被明显遮挡，请选择轮廓更完整的照片。"
    case .imageTooBlurry: "照片较模糊，请选择更清晰的照片。"
    case .imageExposureUnusable: "照片过亮或过暗，请选择光线更均匀的照片。"
    case .deviceCapabilityUnavailable: "当前设备暂时无法完成本机画面检查。"
    case .analysisFailed: "本次检查没有完成，请重试或使用风格化形象。"
    case .qualityWarning: "这张照片可以继续测试，但画面质量可能影响后续效果。"
    }
  }
}
#endif
