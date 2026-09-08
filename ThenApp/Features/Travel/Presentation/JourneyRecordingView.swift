import SwiftUI

struct JourneyRecordingView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: JourneyRecordingViewModel

  init(environment: AppEnvironment, initialPlan: TripPlanSummary?) {
    _model = State(
      initialValue: JourneyRecordingViewModel(
        service: environment.journeyRecording,
        initialPlan: initialPlan
      ))
  }

  var body: some View {
    NavigationStack {
      Form {
        if let journey = model.journey {
          statusSection(journey)
          actionSection(journey)
        } else {
          Section("开始前") {
            Label("只在你主动开始后记录位置", systemImage: "location.circle")
            Label("使用“使用 App 期间”，不请求“始终”定位", systemImage: "hand.raised")
            Label("确认摘要后立即删除原始轨迹", systemImage: "trash")
            Button("开始记录", systemImage: "record.circle") {
              Task { await model.start() }
            }
            .disabled(!model.canStart || model.isWorking)
          }
        }

        if let error = model.errorMessage {
          Section {
            Label {
              Text(error)
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
          }
        }
      }
      .navigationTitle("实际行程")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { dismiss() }
        }
      }
      .overlay {
        if model.isWorking { ProgressView() }
      }
      .task { await model.load() }
    }
  }

  @ViewBuilder
  private func statusSection(_ journey: JourneySnapshot) -> some View {
    Section("记录状态") {
      LabeledContent("状态", value: statusTitle(journey.status))
      LabeledContent(
        "开始",
        value: journey.startedAt.formatted(date: .abbreviated, time: .standard)
      )
      if let endedAt = journey.endedAt {
        LabeledContent(
          "结束",
          value: endedAt.formatted(date: .abbreviated, time: .standard)
        )
      }
      if let pointCount = journey.pointCount {
        LabeledContent("采样", value: "\(pointCount) 个")
      }
      if let distance = journey.distanceMeters {
        LabeledContent(
          "距离",
          value: Measurement(value: distance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated))
        )
      }
      LabeledContent("完整性", value: completenessTitle(journey.captureCompleteness))
      if let reason = journey.pauseReason {
        Text(interruptionTitle(reason))
          .foregroundStyle(.orange)
      }
      if journey.status == .reviewing {
        Text("确认后只保留时间、距离和完整性摘要，并立即删除全部原始轨迹点。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func actionSection(_ journey: JourneySnapshot) -> some View {
    Section("操作") {
      switch journey.status {
      case .recording:
        Button("暂停", systemImage: "pause.circle") {
          Task { await model.pause() }
        }
        Button("结束并生成摘要", systemImage: "stop.circle") {
          Task { await model.end() }
        }
      case .paused:
        Button("继续记录（新片段）", systemImage: "play.circle") {
          Task { await model.resume() }
        }
        Button("结束并生成摘要", systemImage: "stop.circle") {
          Task { await model.end() }
        }
      case .finalizing:
        Button("重试生成摘要", systemImage: "arrow.clockwise") {
          Task { await model.retryFinalization() }
        }
      case .reviewing:
        Button("确认摘要并删除原始轨迹", systemImage: "checkmark.circle") {
          Task { await model.confirm() }
        }
        Button("继续记录（新片段）", systemImage: "play.circle") {
          Task { await model.resume() }
        }
      case .completed, .discarded:
        Text(journey.status == .completed ? "摘要已保存，原始轨迹已删除。" : "行程已丢弃，原始轨迹已删除。")
      }

      if journey.status != .completed, journey.status != .discarded {
        Button("丢弃行程并删除原始轨迹", systemImage: "trash", role: .destructive) {
          Task { await model.discard() }
        }
      }
    }
    .disabled(model.isWorking)
  }

  private func statusTitle(_ status: JourneyStatus) -> String {
    switch status {
    case .recording: "记录中"
    case .paused: "已暂停"
    case .finalizing: "正在生成摘要"
    case .reviewing: "等待确认摘要"
    case .completed: "已完成"
    case .discarded: "已丢弃"
    }
  }

  private func completenessTitle(_ completeness: JourneyCaptureCompleteness) -> String {
    switch completeness {
    case .none: "无轨迹"
    case .partial: "部分轨迹"
    case .complete: "完整"
    }
  }

  private func interruptionTitle(_ reason: JourneyInterruptionReason) -> String {
    switch reason {
    case .permissionDenied: "定位未授权，可以到系统设置开启后继续。"
    case .authorizationRestricted: "系统限制了定位授权。"
    case .locationServicesDisabled: "系统定位服务已关闭。"
    case .locationUnavailable: "当前位置暂时不可用。"
    case .insufficientlyInUse: "系统暂停了后台定位活动。"
    case .accuracyLimited: "定位精度受限，已有片段仍会保留。"
    case .storageFailure: "存储失败，记录已暂停。"
    case .systemInterruption: "记录意外中断，请选择继续或结束。"
    case .userPaused: "你已暂停记录。"
    }
  }
}
