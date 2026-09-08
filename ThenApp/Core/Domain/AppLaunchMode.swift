enum AppLaunchMode: Equatable, Sendable {
  case local

  var requiresAccount: Bool {
    false
  }

  var requiresNetwork: Bool {
    false
  }
}
