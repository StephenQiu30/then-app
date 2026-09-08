import SwiftUI

struct MyView: View {
  @Environment(\.colorScheme) private var colorScheme
  @State private var model: MyViewModel
  @State private var isConfirmingCalendarClear = false
  @State private var isConfirmingLocalReset = false
  private let onLocalDataReset: @MainActor () -> Void

  init(
    permissionStatus: any PermissionStatusService,
    localData: any LocalDataManaging,
    onLocalDataReset: @escaping @MainActor () -> Void
  ) {
    _model = State(
      initialValue: MyViewModel(
        permissionStatus: permissionStatus,
        localData: localData
      )
    )
    self.onLocalDataReset = onLocalDataReset
  }

  var body: some View {
    NavigationStack {
      List {
        Section("运行方式") {
          LabeledContent("数据模式", value: "单设备本地")
          Text("无需账号；P0 不上传账务、日历或位置数据，也不显示不可用的云功能。")
            .font(.caption)
            .foregroundStyle(.primary)
        }

        Section("系统权限") {
          if let permissions = model.permissions {
            permissionRow("日历", state: permissions.calendar)
            permissionRow("通知", state: permissions.notifications)
            permissionRow("位置", state: permissions.location)
            permissionRow("相机", state: permissions.camera)
          } else {
            ProgressView("正在读取权限状态")
          }
        }

        Section("本地保留规则") {
          Label("票据图片只在当前识别会话使用，不保存原图。", systemImage: "doc.viewfinder")
            .fixedSize(horizontal: false, vertical: true)
          Label("定位只在主动记录行程后开始。", systemImage: "location")
            .fixedSize(horizontal: false, vertical: true)
          Label("确认摘要或丢弃后删除原始轨迹。", systemImage: "trash")
            .fixedSize(horizontal: false, vertical: true)
          Label("日历只缓存已选择来源的最小事件字段。", systemImage: "calendar.badge.checkmark")
            .fixedSize(horizontal: false, vertical: true)
        }

        Section("数据控制") {
          Button("导出结构化数据", systemImage: "square.and.arrow.up") {
            Task { await model.createExport() }
          }
          Button("清理日历缓存", systemImage: "calendar.badge.minus") {
            isConfirmingCalendarClear = true
          }
          Button(role: .destructive) {
            isConfirmingLocalReset = true
          } label: {
            Label("删除本机全部数据", systemImage: "trash")
              .foregroundStyle(accessibleDestructiveColor)
          }
          Text("导出不含票据图片、系统日历身份或原始轨迹。删除全部数据后会创建新的空本地资料。")
            .font(.caption)
            .foregroundStyle(.primary)
        }

        if let dataMessage = model.dataMessage {
          Section {
            Label(dataMessage, systemImage: "checkmark.circle")
              .foregroundStyle(.green)
          }
        }

        if let dataError = model.dataError {
          Section {
            Label(dataError, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
          }
        }

        Section("诊断与关于") {
          LabeledContent("App", value: model.releaseInformation.appName)
          LabeledContent("版本", value: model.releaseInformation.versionAndBuild ?? "未知")
          LabeledContent("数据模式", value: "单设备本地")
          LabeledContent("诊断收集", value: "未启用")
          Text("P0 不生成或导出日志、崩溃报告、分析事件或诊断包。反馈问题时只需说明版本号，不要附带账务、日历或位置正文。")
            .font(.caption)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .headerProminence(.increased)
      .modifier(AdaptiveHardScrollEdgeEffectModifier())
      .navigationTitle("我的")
      .task { await model.load() }
      .refreshable { await model.load() }
      .disabled(model.isManagingData)
      .overlay {
        if model.isManagingData { ProgressView() }
      }
      .confirmationDialog(
        "清理日历缓存？",
        isPresented: $isConfirmingCalendarClear,
        titleVisibility: .visible
      ) {
        Button("清理缓存", role: .destructive) {
          Task { await model.clearCalendarCache() }
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("将删除本地日历来源和事件快照，但保留已确认的计划、提醒、行程和账务；系统日历原始事件不会改变。")
      }
      .alert("删除本机全部数据？", isPresented: $isConfirmingLocalReset) {
        Button("永久删除", role: .destructive) {
          Task {
            if await model.resetAllLocalData() {
              onLocalDataReset()
            }
          }
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("账务、日历缓存、计划、行程和关系都会被删除；操作成功后会创建新的空本地资料，且无法撤销。")
      }
      .sheet(
        item: $model.exportArtifact,
        onDismiss: {
          Task { await model.finishSharing() }
        }
      ) { artifact in
        LocalDataShareSheet(fileURL: artifact.fileURL) {
          Task { await model.finishSharing() }
        }
      }
    }
  }

  private func permissionRow(
    _ title: LocalizedStringKey,
    state: DevicePermissionState
  ) -> some View {
    LabeledContent(title) {
      Text(permissionTitle(state))
        .foregroundStyle(state == .allowed ? .green : .primary)
    }
  }

  private func permissionTitle(_ state: DevicePermissionState) -> String {
    switch state {
    case .notRequested: "尚未请求"
    case .allowed: "已允许"
    case .denied: "已拒绝"
    case .restricted: "受系统限制"
    case .limited: "权限不足"
    case .unavailable: "不可用"
    }
  }

  private var accessibleDestructiveColor: Color {
    switch colorScheme {
    case .dark:
      Color(red: 1.00, green: 0.48, blue: 0.45)
    default:
      Color(red: 0.69, green: 0.00, blue: 0.13)
    }
  }

}
