import Foundation
import MapKit
import UIKit

actor MapKitPlaceSearchService: PlaceSearchService {
  func search(query: String) async throws -> [PlaceCandidate] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    let response = try await MKLocalSearch(request: request).start()
    return response.mapItems.prefix(8).map { item in
      let coordinate = item.placemark.coordinate
      return PlaceCandidate(
        id: UUID(),
        name: item.name ?? item.placemark.title ?? "未命名地点",
        address: item.placemark.title,
        latitude: coordinate.latitude,
        longitude: coordinate.longitude
      )
    }
  }
}

actor MapKitRoutePlanningService: RoutePlanningService {
  private let now: @Sendable () -> Date
  private let validity: TimeInterval

  init(
    now: @escaping @Sendable () -> Date = Date.init,
    validity: TimeInterval = 15 * 60
  ) {
    self.now = now
    self.validity = validity
  }

  func route(for input: RoutePlanningRequest) async throws -> RouteEstimateDraft {
    guard input.origin.latitude != nil,
      input.origin.longitude != nil,
      input.destination.latitude != nil,
      input.destination.longitude != nil
    else {
      throw TripPlanningError.routeRequiresOrigin
    }
    let request = MKDirections.Request()
    request.source = Self.mapItem(for: input.origin)
    request.destination = Self.mapItem(for: input.destination)
    request.transportType = Self.transportType(input.transportMode)
    request.arrivalDate = input.targetArrivalAt
    request.requestsAlternateRoutes = true

    let response = try await MKDirections(request: request).calculate()
    guard
      let route = response.routes.min(by: {
        $0.expectedTravelTime < $1.expectedTravelTime
      }), route.expectedTravelTime > 0, route.distance >= 0
    else {
      throw TripPlanningError.routeUnavailable
    }
    let calculatedAt = now()
    return RouteEstimateDraft(
      id: UUID(),
      origin: input.origin,
      destination: input.destination,
      transportMode: input.transportMode,
      distanceMeters: route.distance,
      expectedTravelSeconds: route.expectedTravelTime,
      calculatedAt: calculatedAt,
      expiresAt: calculatedAt.addingTimeInterval(validity)
    )
  }

  private static func mapItem(for location: ConfirmedLocation) -> MKMapItem {
    guard let latitude = location.latitude, let longitude = location.longitude else {
      return MKMapItem()
    }
    let coordinate = CLLocationCoordinate2D(
      latitude: latitude,
      longitude: longitude
    )
    let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    item.name = location.name
    return item
  }

  private static func transportType(_ mode: TripTransportMode) -> MKDirectionsTransportType {
    switch mode {
    case .walking:
      .walking
    case .driving:
      .automobile
    case .transit:
      .transit
    }
  }
}

@MainActor
protocol DestinationClipboard: AnyObject {
  func copy(_ text: String)
}

@MainActor
final class SystemDestinationClipboard: DestinationClipboard {
  func copy(_ text: String) {
    UIPasteboard.general.string = text
  }
}

nonisolated struct AppleMapsNavigationService: ExternalNavigationService {
  @MainActor
  func openAppleMaps(
    destination: ConfirmedLocation,
    transportMode: TripTransportMode
  ) async -> Bool {
    guard let latitude = destination.latitude, let longitude = destination.longitude else {
      let query = destination.address ?? destination.name
      guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
        let url = URL(string: "https://maps.apple.com/?daddr=\(encoded)")
      else {
        return false
      }
      return await UIApplication.shared.open(url)
    }
    let coordinate = CLLocationCoordinate2D(
      latitude: latitude,
      longitude: longitude
    )
    let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    mapItem.name = destination.name
    return MKMapItem.openMaps(
      with: [mapItem],
      launchOptions: [
        MKLaunchOptionsDirectionsModeKey: Self.directionsMode(transportMode)
      ]
    )
  }

  private nonisolated static func directionsMode(_ mode: TripTransportMode) -> String {
    switch mode {
    case .walking:
      MKLaunchOptionsDirectionsModeWalking
    case .driving:
      MKLaunchOptionsDirectionsModeDriving
    case .transit:
      MKLaunchOptionsDirectionsModeTransit
    }
  }
}
