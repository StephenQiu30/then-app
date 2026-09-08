import Foundation
import SwiftUI

nonisolated enum RootTab: String, CaseIterable, Sendable {
  case today
  case ledger
  case calendar
  case travel
  case profile
}

struct RootView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorScheme) private var colorScheme

  let environment: AppEnvironment
  let onLocalDataReset: @MainActor () -> Void

  var body: some View {
    ZStack {
      rootContent

      if PrivacyCoverPolicy.hidesSensitiveContent(for: scenePhase) {
        PrivacyCoverView()
          .zIndex(1)
      }
    }
    .tint(accessibleActionColor)
  }

  @ViewBuilder
  private var rootContent: some View {
    #if DEBUG
      if let destination = AccessibilityAuditDestination.current {
        accessibilityAuditContent(destination)
      } else {
        mainTabView
      }
    #else
      mainTabView
    #endif
  }

  private var mainTabView: some View {
    TabView {
      TodayView(environment: environment)
        .tag(RootTab.today)
        .tabItem {
          Label("今天", systemImage: "sun.max")
        }

      LedgerView(environment: environment)
        .tag(RootTab.ledger)
        .tabItem {
          Label("账本", systemImage: "books.vertical")
        }

      CalendarView(environment: environment)
        .tag(RootTab.calendar)
        .tabItem {
          Label("日程", systemImage: "calendar")
        }

      NavigationStack {
        TripPlanListView(environment: environment)
      }
      .tag(RootTab.travel)
      .tabItem {
        Label("行程", systemImage: "figure.walk.departure")
      }

      MyView(
        permissionStatus: environment.permissionStatus,
        localData: environment.localData,
        onLocalDataReset: onLocalDataReset
      )
      .tag(RootTab.profile)
      .tabItem {
        Label("我的", systemImage: "person.crop.circle")
      }
    }
    .modifier(AdaptiveTabBarMinimizeModifier())
  }

  #if DEBUG
    @ViewBuilder
    private func accessibilityAuditContent(
      _ destination: AccessibilityAuditDestination
    ) -> some View {
      switch destination {
      case .today:
        TodayView(environment: environment)
      case .ledger:
        LedgerView(environment: environment)
      case .calendar:
        CalendarView(environment: environment)
      case .travel:
        NavigationStack {
          TripPlanListView(environment: environment)
        }
      case .profile:
        MyView(
          permissionStatus: environment.permissionStatus,
          localData: environment.localData,
          onLocalDataReset: onLocalDataReset
        )
      }
    }
  #endif

  private var accessibleActionColor: Color {
    switch colorScheme {
    case .dark:
      Color(red: 0.40, green: 0.71, blue: 1.00)
    default:
      Color(red: 0.00, green: 0.29, blue: 0.62)
    }
  }
}

#if DEBUG
  private enum AccessibilityAuditDestination: String {
    case today
    case ledger
    case calendar
    case travel
    case profile

    private static let argumentPrefix = "--then-accessibility-audit-destination="

    static var current: Self? {
      guard
        let argument = ProcessInfo.processInfo.arguments.first(where: {
          $0.hasPrefix(argumentPrefix)
        })
      else {
        return nil
      }
      return Self(rawValue: String(argument.dropFirst(argumentPrefix.count)))
    }
  }
#endif

private struct AdaptiveTabBarMinimizeModifier: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.tabBarMinimizeBehavior(.onScrollDown)
    } else {
      content
    }
  }
}

struct AdaptiveHardScrollEdgeEffectModifier: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.scrollEdgeEffectStyle(.hard, for: .all)
    } else {
      content
    }
  }
}

nonisolated enum PrivacyCoverPolicy {
  static func hidesSensitiveContent(for scenePhase: ScenePhase) -> Bool {
    switch scenePhase {
    case .active:
      false
    case .inactive, .background:
      true
    @unknown default:
      true
    }
  }
}

private struct PrivacyCoverView: View {
  var body: some View {
    ZStack {
      Color(.systemBackground)
        .ignoresSafeArea()
      VStack(spacing: 12) {
        Image(systemName: "lock.shield")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
        Text("于是")
          .font(.headline)
        Text("内容已隐藏")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("于是，内容已隐藏")
  }
}
