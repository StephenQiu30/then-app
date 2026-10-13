import SwiftUI

struct RecommendationView: View {
  @Bindable var model: RecommendationViewModel

  var body: some View {
    Form {
      Section {
        Text("今天的场景")
          .font(.headline)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        Picker("正式度", selection: $model.formality) {
          Text("未指定").tag(WardrobeFormalityBand?.none)
          Text("休闲").tag(WardrobeFormalityBand?.some(.casual))
          Text("通勤得体").tag(WardrobeFormalityBand?.some(.smartCasual))
          Text("正式").tag(WardrobeFormalityBand?.some(.formal))
        }
        Picker("保暖度", selection: $model.warmth) {
          Text("未指定").tag(WardrobeWarmthBand?.none)
          Text("轻薄").tag(WardrobeWarmthBand?.some(.light))
          Text("适中").tag(WardrobeWarmthBand?.some(.medium))
          Text("保暖").tag(WardrobeWarmthBand?.some(.warm))
        }
        Toggle("必须适合雨天", isOn: $model.requiresRainSuitability)
        Toggle("必须适合步行", isOn: $model.requiresWalkingSuitability)
        Toggle("本次可使用已打包衣物", isOn: $model.includesPackedItems)
      }

      Section {
        Button {
          Task { await model.generate() }
        } label: {
          Label("生成穿搭建议", systemImage: "sparkles")
            .frame(maxWidth: .infinity)
        }
        .disabled(model.phase == .loading)
        .accessibilityIdentifier("recommendation.generate")
        Text("只使用你衣橱中的真实衣物。本次选择保留在当前页面，不使用照片或网络。")
          .font(.footnote)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }

      result
    }
    .navigationTitle("穿搭建议")
    .navigationBarTitleDisplayMode(.inline)
    .onDisappear { model.clearSession() }
  }

  @ViewBuilder private var result: some View {
    switch model.phase {
    case .idle:
      EmptyView()
    case .loading:
      Section { ProgressView("正在检查衣橱…") }
    case .failed:
      Section {
        ContentUnavailableView("暂时无法读取衣橱", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
        Button("重试") { Task { await model.generate() } }
      }
    case .noSolution(let gap):
      Section("暂时没有可行组合") {
        Label(gapTitle(gap), systemImage: "hanger")
          .accessibilityIdentifier("recommendation.no-solution")
        Text(gapAction(gap)).foregroundStyle(.secondary)
      }
    case .candidates(let candidates):
      Section("建议方案") {
        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
          candidateCard(candidate, number: index + 1)
        }
      }
    }
  }

  private func candidateCard(_ candidate: RecommendationCandidate, number: Int) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("方案 \(number)").font(.headline)
      ForEach(candidate.items) { item in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: icon(item.input.category))
            .frame(width: 20)
            .accessibilityHidden(true)
          Text(item.input.name)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(candidate.reasons.map { reasonTitle($0.code) }.joined(separator: " · "))
        .font(.footnote)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      if !candidate.uncertainties.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(candidate.uncertainties, id: \.rawValue) { uncertainty in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: "questionmark.circle")
                .accessibilityHidden(true)
              Text(uncertaintyTitle(uncertainty))
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .font(.footnote)
        .foregroundStyle(.primary)
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("recommendation.candidate.\(number)")
  }

  private func icon(_ category: WardrobeCategory) -> String {
    switch category {
    case .shoes: "shoe"
    case .bag: "handbag"
    default: "tshirt"
    }
  }

  private func reasonTitle(_ code: RecommendationReasonCode) -> String {
    switch code {
    case .realAvailableItems: "当前可用"
    case .completeSeparatePath, .completeOnePiecePath: "组合完整"
    case .confirmedFormality: "正式度已确认"
    case .confirmedWarmth: "保暖度已确认"
    case .confirmedRainShoes: "鞋履适合雨天"
    case .confirmedWalkingShoes: "鞋履适合步行"
    }
  }

  private func uncertaintyTitle(_ code: RecommendationUncertaintyCode) -> String {
    switch code {
    case .someFormalityUnknown: "部分正式度未知"
    case .someWarmthUnknown: "部分保暖度未知"
    case .someRainSuitabilityUnknown: "部分雨天适配未知"
    case .someWalkingSuitabilityUnknown: "部分步行适配未知"
    }
  }

  private func gapTitle(_ gap: RecommendationGapCode) -> String {
    switch gap {
    case .noAvailableItems: "没有当前可用的衣物"
    case .missingTopOrOnePiece: "缺少可用上装或连体衣"
    case .missingBottomForTop: "有上装，但缺少可用下装"
    case .missingShoes: "缺少可用鞋履"
    case .confirmedConstraintsConflict: "现有衣物无法同时满足已选条件"
    }
  }

  private func gapAction(_ gap: RecommendationGapCode) -> String {
    switch gap {
    case .confirmedConstraintsConflict: "可以一次放宽一个条件，或先在衣橱中确认相关属性。"
    default: "请在个人衣橱中补充衣物或更新当前状态后重试。"
    }
  }
}
