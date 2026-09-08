import Foundation
import GRDB
import Testing

@testable import ThenApp

@Suite("出行计划、提醒与导航")
struct TripPlanningTests {
  @Test("普通日历事件保留来源时间并原子建立本地关系")
  @MainActor
  func regularCalendarOccurrenceCreatesLinkedPlan() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let occurrence = try await makePersistedTripOccurrence(
        database: database,
        ownerID: identity.profileID,
        isAllDay: false
      )
      let repository = GRDBTripPlanRepository(database: database)
      let service = makeTripPlanningService(
        ownerID: identity.profileID,
        repository: repository,
        reminder: FixedReminderService(state: .denied),
        navigation: FixedNavigationService(didOpen: true)
      )
      let model = TripPlanEditorViewModel(
        ownerID: identity.profileID,
        service: service,
        seed: TripPlanEditorSeed(occurrence: occurrence),
        now: { tripDate(1_000) }
      )

      #expect(model.displayName == "日历会议")
      #expect(model.destinationQuery == "合成会场")
      #expect(model.targetArrivalAt == occurrence.startsAt)
      #expect(model.hasConfirmedAllDayTime)
      #expect(!model.canSave)

      model.useManualDestination()
      #expect(model.canSave)
      await model.save()

      let saved = try #require(model.savedResult?.plan)
      #expect(saved.displayName == "日历会议")
      #expect(saved.destination.name == "合成会场")
      #expect(saved.targetArrivalAt == occurrence.startsAt)
      #expect(saved.reminderStatus == .disabled)

      let snapshot = try await eventPlanSnapshot(
        database: database,
        planID: saved.id,
        occurrenceID: occurrence.id
      )
      #expect(snapshot.planSourceVersion == occurrence.sourceVersion)
      #expect(snapshot.targetArrivalValueSource == "event")
      #expect(snapshot.targetArrivalOverriddenAt == nil)
      #expect(snapshot.destinationValueSource == "user")
      #expect(snapshot.destinationOverriddenAt == tripDate(1_000).timeIntervalSince1970)
      #expect(snapshot.linkOccurrenceID == occurrence.id.uuidString.lowercased())
      #expect(snapshot.linkSourceVersion == occurrence.sourceVersion)
      #expect(snapshot.reminderStatus == "disabled")
      #expect(snapshot.reminderFollowsSource == false)
      #expect(snapshot.occurrenceTitle == "日历会议")
      #expect(snapshot.occurrenceLocation == "合成会场")
      #expect(snapshot.occurrenceState == "active")
      #expect(snapshot.occurrenceSourceVersion == occurrence.sourceVersion)
    }
  }

  @Test("日历重扫只产生来源变化且不覆盖已确认计划")
  @MainActor
  func calendarRescanDoesNotOverwriteConfirmedPlan() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let occurrence = try await makePersistedTripOccurrence(
        database: database,
        ownerID: identity.profileID,
        isAllDay: false
      )
      let tripRepository = GRDBTripPlanRepository(database: database)
      let service = makeTripPlanningService(
        ownerID: identity.profileID,
        repository: tripRepository,
        reminder: FixedReminderService(state: .denied),
        navigation: FixedNavigationService(didOpen: true)
      )
      let model = TripPlanEditorViewModel(
        ownerID: identity.profileID,
        service: service,
        seed: TripPlanEditorSeed(occurrence: occurrence),
        now: { tripDate(1_000) }
      )
      model.useManualDestination()
      await model.save()
      let saved = try #require(model.savedResult?.plan)
      let savedDepartureAt = try #require(saved.plannedDepartureAt)

      let changedOccurrence = try await rescanPersistedTripOccurrence(
        database: database,
        ownerID: identity.profileID,
        startsAt: tripDate(3_300),
        title: "改期后的会议",
        locationText: "新的合成会场"
      )
      let snapshot = try await eventPlanSnapshot(
        database: database,
        planID: saved.id,
        occurrenceID: occurrence.id
      )
      let revisionCount = try await database.pool.read { database in
        try Int.fetchOne(
          database,
          sql:
            "SELECT COUNT(*) FROM calendar_occurrence_revisions WHERE calendar_occurrence_id = ?",
          arguments: [occurrence.id.uuidString.lowercased()]
        ) ?? 0
      }

      #expect(changedOccurrence.id == occurrence.id)
      #expect(changedOccurrence.sourceVersion == occurrence.sourceVersion + 1)
      #expect(changedOccurrence.title == "改期后的会议")
      #expect(changedOccurrence.locationText == "新的合成会场")
      #expect(changedOccurrence.startsAt == tripDate(3_300))
      #expect(changedOccurrence.hasPendingRevision)
      #expect(revisionCount == 1)

      #expect(snapshot.planDisplayName == saved.displayName)
      #expect(snapshot.planTargetArrivalAt == saved.targetArrivalAt.timeIntervalSince1970)
      #expect(snapshot.planDepartureAt == savedDepartureAt.timeIntervalSince1970)
      #expect(snapshot.destinationName == saved.destination.name)
      #expect(snapshot.destinationAddress == saved.destination.address)
      #expect(snapshot.planSourceVersion == occurrence.sourceVersion)
      #expect(snapshot.linkSourceVersion == occurrence.sourceVersion)
      #expect(snapshot.targetArrivalValueSource == "event")
      #expect(snapshot.reminderStatus == "disabled")
      #expect(snapshot.reminderFollowsSource == false)
      #expect(snapshot.occurrenceSourceVersion == occurrence.sourceVersion + 1)
    }
  }

  @Test("同一日历事件重复创建计划在写入前闭合失败")
  func duplicateEventPlanIsRejectedWithoutPartialRows() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let occurrence = try await makePersistedTripOccurrence(
        database: database,
        ownerID: identity.profileID,
        isAllDay: false
      )
      let repository = GRDBTripPlanRepository(database: database)
      let eventSource = TripPlanEventSource(
        occurrenceID: occurrence.id,
        sourceVersion: occurrence.sourceVersion
      )
      _ = try await repository.savePlan(
        makeSaveRequest(
          ownerID: identity.profileID,
          destination: makeTripLocation(byte: 0x61, name: "首个计划地点"),
          reminderEnabled: false,
          eventSource: eventSource,
          targetArrivalValueSource: .event
        )
      )

      do {
        _ = try await repository.savePlan(
          makeSaveRequest(
            ownerID: identity.profileID,
            destination: makeTripLocation(byte: 0x62, name: "不应保留的重复地点"),
            reminderEnabled: false,
            eventSource: eventSource,
            targetArrivalValueSource: .event
          )
        )
        Issue.record("同一 occurrence 不得创建第二个产品计划")
      } catch let error as TripPlanningError {
        #expect(error == .eventAlreadyLinked)
      }

      let counts = try await database.pool.read { database in
        (
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM trip_plans") ?? -1,
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM event_trip_links") ?? -1,
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM location_snapshots") ?? -1,
          try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM location_snapshots WHERE name = '不应保留的重复地点'"
          ) ?? -1
        )
      }
      #expect(counts == (1, 1, 1, 0))
    }
  }

  @Test("显式采用来源变化原子推进版本并使旧路线失效")
  func adoptingRevisionUpdatesPlanLinkReminderAndRevision() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let occurrence = try await makePersistedTripOccurrence(
        database: database,
        ownerID: identity.profileID,
        isAllDay: false
      )
      let repository = GRDBTripPlanRepository(database: database)
      let origin = makeTripLocation(byte: 0x63, name: "旧起点")
      let oldDestination = makeTripLocation(byte: 0x64, name: "旧目的地")
      let route = RouteEstimateDraft(
        id: UUID(),
        origin: origin,
        destination: oldDestination,
        transportMode: .driving,
        distanceMeters: 8_000,
        expectedTravelSeconds: 1_000,
        calculatedAt: tripDate(1_010),
        expiresAt: tripDate(1_910)
      )
      let original = try await repository.savePlan(
        makeSaveRequest(
          ownerID: identity.profileID,
          origin: origin,
          destination: oldDestination,
          targetArrival: occurrence.startsAt,
          departure: tripDate(2_000),
          route: route,
          reminderEnabled: false,
          eventSource: TripPlanEventSource(
            occurrenceID: occurrence.id,
            sourceVersion: occurrence.sourceVersion
          ),
          targetArrivalValueSource: .event
        )
      )
      let changed = try await rescanPersistedTripOccurrence(
        database: database,
        ownerID: identity.profileID,
        startsAt: tripDate(3_300),
        title: "改期后的会议",
        locationText: "新地点文本"
      )
      let newDestination = ConfirmedLocation(
        id: UUID(),
        name: "用户确认的新地点",
        address: "新地点文本",
        latitude: nil,
        longitude: nil,
        source: .manual,
        horizontalAccuracy: nil
      )
      let reminder = FixedReminderService(state: .denied)
      let service = makeTripPlanningService(
        ownerID: identity.profileID,
        repository: repository,
        reminder: reminder,
        navigation: FixedNavigationService(didOpen: true),
        now: { tripDate(1_200) }
      )

      let result = try await service.adoptCalendarRevision(
        AdoptCalendarRevisionRequest(
          ownerID: identity.profileID,
          planID: original.id,
          occurrenceID: occurrence.id,
          expectedPlanVersion: original.planVersion,
          expectedAdoptedSourceVersion: try #require(original.sourceOccurrenceVersion),
          throughSourceVersion: changed.sourceVersion,
          displayName: changed.title,
          origin: origin,
          destination: newDestination,
          transportMode: .driving,
          targetArrivalAt: changed.startsAt,
          plannedDepartureAt: tripDate(2_500),
          timezoneIdentifier: changed.timeZoneIdentifier,
          preparationBufferSeconds: 600,
          routeEstimate: nil,
          displayNameValueSource: .event,
          destinationValueSource: .user,
          targetArrivalValueSource: .event,
          departureValueSource: .user,
          reminderEnabled: true,
          reminderFollowsSource: false,
          submittedAt: tripDate(1_200)
        )
      )

      #expect(result.plan.planVersion == original.planVersion + 1)
      #expect(result.plan.sourceOccurrenceVersion == changed.sourceVersion)
      #expect(result.plan.displayName == "改期后的会议")
      #expect(result.plan.destination == newDestination)
      #expect(result.plan.targetArrivalAt == changed.startsAt)
      #expect(result.plan.routeEstimate == nil)
      #expect(result.plan.reminderStatus == .authorizationDenied)
      #expect(result.reminderMessage == "已采用来源变化，但通知未获授权。")
      #expect(await reminder.scheduledRequests().isEmpty)

      let persisted = try await database.pool.read { database in
        let plan = try #require(
          try Row.fetchOne(
            database,
            sql: """
              SELECT plan_version, source_occurrence_version, selected_route_estimate_id
              FROM trip_plans WHERE id = ?
              """,
            arguments: [original.id.uuidString.lowercased()]
          )
        )
        let linkVersion = try Int.fetchOne(
          database,
          sql: "SELECT source_occurrence_version FROM event_trip_links WHERE trip_plan_id = ?",
          arguments: [original.id.uuidString.lowercased()]
        )
        let reminder = try #require(
          try Row.fetchOne(
            database,
            sql: """
              SELECT schedule_version, is_enabled, status
              FROM departure_reminders WHERE trip_plan_id = ?
              """,
            arguments: [original.id.uuidString.lowercased()]
          )
        )
        let revision = try #require(
          try Row.fetchOne(
            database,
            sql: """
              SELECT resolution_state, resolved_at
              FROM calendar_occurrence_revisions
              WHERE calendar_occurrence_id = ? AND to_version = ?
              """,
            arguments: [occurrence.id.uuidString.lowercased(), changed.sourceVersion]
          )
        )
        return (
          plan["plan_version"] as Int,
          plan["source_occurrence_version"] as Int,
          plan["selected_route_estimate_id"] as String?,
          linkVersion,
          reminder["schedule_version"] as Int,
          reminder["is_enabled"] as Bool,
          reminder["status"] as String,
          revision["resolution_state"] as String,
          revision["resolved_at"] as Double?,
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM route_estimates") ?? -1
        )
      }
      #expect(persisted.0 == 2)
      #expect(persisted.1 == changed.sourceVersion)
      #expect(persisted.2 == nil)
      #expect(persisted.3 == changed.sourceVersion)
      #expect(persisted.4 == 2)
      #expect(persisted.5)
      #expect(persisted.6 == "authorization_denied")
      #expect(persisted.7 == "accepted")
      #expect(persisted.8 == tripDate(1_200).timeIntervalSince1970)
      #expect(persisted.9 == 0)
    }
  }

  @Test("陈旧计划版本与历史重复关系均拒绝采用且保留待处理变化")
  func staleOrAmbiguousAdoptionDoesNotMutateRevision() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let occurrence = try await makePersistedTripOccurrence(
        database: database,
        ownerID: identity.profileID,
        isAllDay: false
      )
      let repository = GRDBTripPlanRepository(database: database)
      let first = try await repository.savePlan(
        makeSaveRequest(
          ownerID: identity.profileID,
          destination: makeTripLocation(byte: 0x65, name: "已有地点"),
          targetArrival: occurrence.startsAt,
          reminderEnabled: false,
          eventSource: TripPlanEventSource(
            occurrenceID: occurrence.id,
            sourceVersion: occurrence.sourceVersion
          ),
          targetArrivalValueSource: .event
        )
      )
      let changed = try await rescanPersistedTripOccurrence(
        database: database,
        ownerID: identity.profileID,
        startsAt: tripDate(3_300),
        title: "新的标题",
        locationText: "新的地点"
      )
      let request = AdoptCalendarRevisionRequest(
        ownerID: identity.profileID,
        planID: first.id,
        occurrenceID: occurrence.id,
        expectedPlanVersion: first.planVersion,
        expectedAdoptedSourceVersion: occurrence.sourceVersion,
        throughSourceVersion: changed.sourceVersion,
        displayName: changed.title,
        origin: nil,
        destination: makeTripLocation(byte: 0x66, name: "待采用地点"),
        transportMode: .driving,
        targetArrivalAt: changed.startsAt,
        plannedDepartureAt: tripDate(2_400),
        timezoneIdentifier: changed.timeZoneIdentifier,
        preparationBufferSeconds: 600,
        routeEstimate: nil,
        displayNameValueSource: .event,
        destinationValueSource: .user,
        targetArrivalValueSource: .event,
        departureValueSource: .user,
        reminderEnabled: false,
        reminderFollowsSource: false,
        submittedAt: tripDate(1_200)
      )

      try await database.pool.write { database in
        try database.execute(
          sql: "UPDATE trip_plans SET plan_version = plan_version + 1 WHERE id = ?",
          arguments: [first.id.uuidString.lowercased()]
        )
      }
      do {
        _ = try await repository.adoptCalendarRevision(request)
        Issue.record("陈旧计划页面不得覆盖新版本")
      } catch let error as TripPlanningError {
        #expect(error == .stalePlanVersion)
      }
      var pendingCount = try await pendingRevisionCount(
        database: database,
        occurrenceID: occurrence.id
      )
      #expect(pendingCount == 1)

      let second = try await repository.savePlan(
        makeSaveRequest(
          ownerID: identity.profileID,
          destination: makeTripLocation(byte: 0x67, name: "历史重复计划"),
          reminderEnabled: false
        )
      )
      try await database.pool.write { database in
        try database.execute(
          sql: """
            INSERT INTO event_trip_links (
              id, owner_id, calendar_occurrence_id, trip_plan_id,
              source_occurrence_version, created_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            UUID().uuidString.lowercased(),
            identity.profileID.uuidString.lowercased(),
            occurrence.id.uuidString.lowercased(),
            second.id.uuidString.lowercased(),
            occurrence.sourceVersion,
            tripDate(1_150).timeIntervalSince1970,
          ]
        )
      }
      #expect(
        try await repository.linkedPlans(ownerID: identity.profileID, occurrenceID: occurrence.id)
          .count == 2)
      do {
        _ = try await repository.adoptCalendarRevision(request)
        Issue.record("历史重复关系不得猜测要修改的计划")
      } catch let error as TripPlanningError {
        #expect(error == .multipleEventPlans)
      }
      pendingCount = try await pendingRevisionCount(
        database: database,
        occurrenceID: occurrence.id
      )
      #expect(pendingCount == 1)
      let uncommittedDestinationCount = try await database.pool.read { database in
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM location_snapshots WHERE name = '待采用地点'"
        ) ?? -1
      }
      #expect(uncommittedDestinationCount == 0)
    }
  }

  @Test("全天事件需显式确认具体时间并作为用户值保存")
  @MainActor
  func allDayOccurrenceRequiresExplicitTimeConfirmation() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let occurrence = try await makePersistedTripOccurrence(
        database: database,
        ownerID: identity.profileID,
        isAllDay: true
      )
      let repository = GRDBTripPlanRepository(database: database)
      let service = makeTripPlanningService(
        ownerID: identity.profileID,
        repository: repository,
        reminder: FixedReminderService(state: .denied),
        navigation: FixedNavigationService(didOpen: true)
      )
      let model = TripPlanEditorViewModel(
        ownerID: identity.profileID,
        service: service,
        seed: TripPlanEditorSeed(occurrence: occurrence),
        now: { tripDate(1_000) }
      )

      model.useManualDestination()
      #expect(!model.hasConfirmedAllDayTime)
      #expect(!model.canSave)
      await model.save()

      let rejectedCounts = try await database.pool.read { database in
        (
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM location_snapshots") ?? -1,
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM trip_plans") ?? -1,
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM departure_reminders") ?? -1,
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM event_trip_links") ?? -1
        )
      }
      #expect(rejectedCounts.0 == 0)
      #expect(rejectedCounts.1 == 0)
      #expect(rejectedCounts.2 == 0)
      #expect(rejectedCounts.3 == 0)

      model.confirmAllDayArrivalTime()
      #expect(model.hasConfirmedAllDayTime)
      #expect(model.canSave)
      await model.save()

      let saved = try #require(model.savedResult?.plan)
      let snapshot = try await eventPlanSnapshot(
        database: database,
        planID: saved.id,
        occurrenceID: occurrence.id
      )
      #expect(snapshot.targetArrivalValueSource == "user")
      #expect(snapshot.targetArrivalOverriddenAt == tripDate(1_000).timeIntervalSince1970)
      #expect(snapshot.linkOccurrenceID == occurrence.id.uuidString.lowercased())
      #expect(snapshot.linkSourceVersion == occurrence.sourceVersion)
      #expect(snapshot.reminderStatus == "disabled")
      #expect(snapshot.occurrenceState == "active")
      #expect(snapshot.occurrenceSourceVersion == occurrence.sourceVersion)
    }
  }

  @Test("失效日历关联使地点计划提醒和关系整体回滚")
  func missingCalendarOccurrenceRollsBackWholePlan() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let repository = GRDBTripPlanRepository(database: database)
      let request = makeSaveRequest(
        ownerID: identity.profileID,
        destination: makeTripLocation(byte: 0x19, name: "不应保留的地点"),
        reminderEnabled: false,
        eventSource: TripPlanEventSource(occurrenceID: UUID(), sourceVersion: 1),
        targetArrivalValueSource: .event
      )

      do {
        _ = try await repository.savePlan(request)
        Issue.record("不存在的 occurrence 必须拒绝整次保存")
      } catch {
        // Foreign-key enforcement is the final repository boundary for a stale local event link.
      }

      let counts = try await database.pool.read { database in
        (
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM location_snapshots") ?? -1,
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM trip_plans") ?? -1,
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM departure_reminders") ?? -1,
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM event_trip_links") ?? -1
        )
      }
      #expect(counts.0 == 0)
      #expect(counts.1 == 0)
      #expect(counts.2 == 0)
      #expect(counts.3 == 0)
    }
  }

  @Test("无路线时可用手动出发时间原子保存计划")
  func manualDepartureSavesWithoutRoute() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let repository = GRDBTripPlanRepository(database: database)
      let planID = UUID()
      let destination = ConfirmedLocation(
        id: UUID(),
        name: "手动目的地",
        address: "合成文字地址",
        latitude: nil,
        longitude: nil,
        source: .manual,
        horizontalAccuracy: nil
      )
      let request = makeSaveRequest(
        planID: planID,
        ownerID: identity.profileID,
        destination: destination,
        route: nil,
        reminderEnabled: false
      )

      let plan = try await repository.savePlan(request)
      #expect(plan.id == planID)
      #expect(plan.origin == nil)
      #expect(plan.destination == destination)
      #expect(plan.routeEstimate == nil)
      #expect(plan.status == .planned)
      #expect(plan.reminderStatus == .disabled)

      let snapshot = try await database.pool.read { database in
        let planCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM trip_plans")
        let locationCount = try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM location_snapshots"
        )
        let reminderCount = try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM departure_reminders"
        )
        return (planCount, locationCount, reminderCount)
      }
      #expect(snapshot == (1, 1, 1))
    }
  }

  @Test("通知拒绝只更新提醒状态且保留已确认计划")
  func deniedReminderPreservesPlan() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let repository = GRDBTripPlanRepository(database: database)
      let reminder = FixedReminderService(state: .denied)
      let service = makeTripPlanningService(
        ownerID: identity.profileID,
        repository: repository,
        reminder: reminder,
        navigation: FixedNavigationService(didOpen: true)
      )
      let request = makeSaveRequest(
        ownerID: identity.profileID,
        destination: makeTripLocation(byte: 0x21, name: "车站"),
        reminderEnabled: true
      )

      let result = try await service.savePlan(request)
      #expect(result.plan.status == .planned)
      #expect(result.plan.reminderStatus == .authorizationDenied)
      #expect(result.plan.reminderFireAt == request.plannedDepartureAt)
      #expect(result.reminderMessage == "计划已保存，但通知未获授权。")
      #expect(await reminder.scheduledRequests().isEmpty)
      #expect(try await service.plans().count == 1)
    }
  }

  @Test("路线快照生成建议时间且普通提醒成功后才标记已调度")
  func routeAndReminderArePersistedWithExplicitState() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let repository = GRDBTripPlanRepository(database: database)
      let origin = makeTripLocation(byte: 0x31, name: "家")
      let destination = makeTripLocation(byte: 0x32, name: "机场")
      let calculatedAt = tripDate(1_100)
      let route = RouteEstimateDraft(
        id: UUID(),
        origin: origin,
        destination: destination,
        transportMode: .driving,
        distanceMeters: 30_500,
        expectedTravelSeconds: 1_800,
        calculatedAt: calculatedAt,
        expiresAt: calculatedAt.addingTimeInterval(900)
      )
      let targetArrival = tripDate(8_000)
      let departure = route.suggestedDeparture(
        targetArrivalAt: targetArrival,
        preparationBufferSeconds: 600
      )
      #expect(departure == tripDate(5_600))

      let reminder = FixedReminderService(state: .authorized)
      let service = makeTripPlanningService(
        ownerID: identity.profileID,
        repository: repository,
        reminder: reminder,
        navigation: FixedNavigationService(didOpen: true)
      )
      let request = makeSaveRequest(
        ownerID: identity.profileID,
        origin: origin,
        destination: destination,
        targetArrival: targetArrival,
        departure: departure,
        route: route,
        reminderEnabled: true,
        departureValueSource: .derived
      )

      let result = try await service.savePlan(request)
      #expect(result.plan.routeEstimate == route)
      #expect(result.plan.reminderStatus == .scheduled)
      #expect(result.reminderMessage == "已向系统安排普通本地提醒。")
      let scheduled = await reminder.scheduledRequests()
      #expect(scheduled.count == 1)
      #expect(scheduled.first?.fireAt == departure)
      #expect(
        scheduled.first?.requestIdentifier.contains(request.planID.uuidString.lowercased()) == true)
    }
  }

  @Test("Apple 地图交接失败被记录且不改变计划状态")
  @MainActor
  func failedNavigationHandoffDoesNotMutatePlan() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let repository = GRDBTripPlanRepository(database: database)
      let service = makeTripPlanningService(
        ownerID: identity.profileID,
        repository: repository,
        reminder: FixedReminderService(state: .denied),
        navigation: FixedNavigationService(didOpen: false)
      )
      let result = try await service.savePlan(
        makeSaveRequest(
          ownerID: identity.profileID,
          destination: makeTripLocation(byte: 0x41, name: "公园"),
          reminderEnabled: false
        )
      )

      do {
        try await service.openAppleMaps(for: result.plan)
        Issue.record("地图打开失败必须返回稳定错误")
      } catch let error as TripPlanningError {
        #expect(error == .navigationOpenFailed)
      }

      let snapshot = try await database.pool.read { database in
        let result = try String.fetchOne(
          database,
          sql: "SELECT result FROM navigation_handoffs"
        )
        let error = try String.fetchOne(
          database,
          sql: "SELECT safe_error_code FROM navigation_handoffs"
        )
        let status = try String.fetchOne(database, sql: "SELECT status FROM trip_plans")
        let journeyCount = try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM journeys"
        )
        return (result, error, status, journeyCount)
      }
      #expect(snapshot.0 == "failed")
      #expect(snapshot.1 == "open_failed")
      #expect(snapshot.2 == "planned")
      #expect(snapshot.3 == 0)
    }
  }

  @Test("导航失败只在显式操作后复制当前计划目的地")
  @MainActor
  func failedNavigationCopiesOnlyAfterExplicitAction() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let repository = GRDBTripPlanRepository(database: database)
      let service = makeTripPlanningService(
        ownerID: identity.profileID,
        repository: repository,
        reminder: FixedReminderService(state: .denied),
        navigation: FixedNavigationService(didOpen: false)
      )
      let addressedPlan = try await service.savePlan(
        makeSaveRequest(
          ownerID: identity.profileID,
          destination: ConfirmedLocation(
            id: UUID(),
            name: "人民广场",
            address: "  上海市黄浦区人民大道  ",
            latitude: 31.2304,
            longitude: 121.4737,
            source: .mapkit,
            horizontalAccuracy: nil
          ),
          reminderEnabled: false
        )
      ).plan
      let nameOnlyPlan = try await service.savePlan(
        makeSaveRequest(
          ownerID: identity.profileID,
          destination: ConfirmedLocation(
            id: UUID(),
            name: "手动博物馆",
            address: " \n ",
            latitude: nil,
            longitude: nil,
            source: .manual,
            horizontalAccuracy: nil
          ),
          reminderEnabled: false
        )
      ).plan
      let recording = JourneyRecordingService(
        ownerID: identity.profileID,
        recordingDeviceID: UUID(),
        repository: GRDBJourneyRepository(database: database),
        locationDriver: SuccessfulJourneyLocationDriver(),
        now: { tripDate(1_100) }
      )
      let clipboard = RecordingDestinationClipboard()
      let model = TripPlanListViewModel(
        service: service,
        journeyNavigation: JourneyNavigationCoordinator(
          recording: recording,
          tripPlanning: service
        ),
        journeyRecording: recording,
        clipboard: clipboard
      )

      await model.openMaps(for: addressedPlan)

      #expect(clipboard.values.isEmpty)
      #expect(model.failedNavigationPlan?.id == addressedPlan.id)
      #expect(model.clipboardConfirmation == nil)

      model.copyFailedDestination()

      #expect(clipboard.values == ["上海市黄浦区人民大道"])
      #expect(model.clipboardConfirmation == "目的地已复制")

      await model.openMaps(for: nameOnlyPlan)

      #expect(clipboard.values == ["上海市黄浦区人民大道"])
      #expect(model.failedNavigationPlan?.id == nameOnlyPlan.id)
      #expect(model.clipboardConfirmation == nil)

      model.copyFailedDestination()

      #expect(clipboard.values == ["上海市黄浦区人民大道", "手动博物馆"])
      #expect(model.clipboardConfirmation == "目的地已复制")
    }
  }

  @Test("联合开始先保存实际行程且地图失败不丢失恢复入口")
  @MainActor
  func combinedStartPersistsJourneyBeforeFailedNavigation() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let tripRepository = GRDBTripPlanRepository(database: database)
      let tripService = makeTripPlanningService(
        ownerID: identity.profileID,
        repository: tripRepository,
        reminder: FixedReminderService(state: .denied),
        navigation: FixedNavigationService(didOpen: false)
      )
      let plan = try await tripService.savePlan(
        makeSaveRequest(
          ownerID: identity.profileID,
          destination: makeTripLocation(byte: 0x42, name: "博物馆"),
          reminderEnabled: false
        )
      ).plan
      let deviceID = UUID()
      let journeyService = JourneyRecordingService(
        ownerID: identity.profileID,
        recordingDeviceID: deviceID,
        repository: GRDBJourneyRepository(database: database),
        locationDriver: SuccessfulJourneyLocationDriver(),
        now: { tripDate(1_100) }
      )
      let coordinator = JourneyNavigationCoordinator(
        recording: journeyService,
        tripPlanning: tripService
      )

      let result = try await coordinator.startRecordingAndOpenMaps(for: plan)

      #expect(!result.didOpenAppleMaps)
      #expect(result.journey.tripPlanID == plan.id)
      #expect(result.journey.status == .recording)
      let current = try await journeyService.currentJourney()
      #expect(current?.id == result.journey.id)
      #expect(current?.tripPlanID == plan.id)

      let snapshot = try await database.pool.read { database in
        let handoffResult = try String.fetchOne(
          database,
          sql: "SELECT result FROM navigation_handoffs"
        )
        let journeyCount = try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM journeys WHERE trip_plan_id = ? AND status = 'recording'",
          arguments: [plan.id.uuidString.lowercased()]
        )
        let planStatus = try String.fetchOne(database, sql: "SELECT status FROM trip_plans")
        return (handoffResult, journeyCount, planStatus)
      }
      #expect(snapshot.0 == "failed")
      #expect(snapshot.1 == 1)
      #expect(snapshot.2 == "planned")
    }
  }

  @Test("联合开始地图失败保留 Journey 与目的地复制降级")
  @MainActor
  func combinedStartFailureKeepsJourneyAndCopyFallback() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let repository = GRDBTripPlanRepository(database: database)
      let service = makeTripPlanningService(
        ownerID: identity.profileID,
        repository: repository,
        reminder: FixedReminderService(state: .denied),
        navigation: FixedNavigationService(didOpen: false)
      )
      let plan = try await service.savePlan(
        makeSaveRequest(
          ownerID: identity.profileID,
          destination: makeTripLocation(byte: 0x43, name: "联合开始终点"),
          reminderEnabled: false
        )
      ).plan
      let recording = JourneyRecordingService(
        ownerID: identity.profileID,
        recordingDeviceID: UUID(),
        repository: GRDBJourneyRepository(database: database),
        locationDriver: SuccessfulJourneyLocationDriver(),
        now: { tripDate(1_100) }
      )
      let clipboard = RecordingDestinationClipboard()
      let model = TripPlanListViewModel(
        service: service,
        journeyNavigation: JourneyNavigationCoordinator(
          recording: recording,
          tripPlanning: service
        ),
        journeyRecording: recording,
        clipboard: clipboard
      )

      let didStart = await model.startRecordingAndOpenMaps(for: plan)

      #expect(didStart)
      #expect(clipboard.values.isEmpty)
      #expect(model.failedNavigationPlan?.id == plan.id)
      let currentJourney = try await recording.currentJourney()
      #expect(currentJourney?.tripPlanID == plan.id)
      #expect(currentJourney?.status == .recording)

      model.copyFailedDestination()

      #expect(clipboard.values == ["合成地址 67"])
      #expect(model.clipboardConfirmation == "目的地已复制")
    }
  }

  @Test("非法到达时间在写入任何计划数据前被拒绝")
  func invalidArrivalDoesNotCreatePartialPlan() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeTripIdentity(database)
      let repository = GRDBTripPlanRepository(database: database)
      let request = makeSaveRequest(
        ownerID: identity.profileID,
        destination: makeTripLocation(byte: 0x51, name: "无效地点"),
        targetArrival: tripDate(900),
        departure: tripDate(800),
        reminderEnabled: false
      )
      do {
        _ = try await repository.savePlan(request)
        Issue.record("过去的到达时间必须被拒绝")
      } catch let error as TripPlanningError {
        #expect(error == .invalidArrivalTime)
      }
      let counts = try await database.pool.read { database in
        let locations = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM location_snapshots")
        let plans = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM trip_plans")
        return (locations, plans)
      }
      #expect(counts == (0, 0))
    }
  }
}

private nonisolated struct EventPlanPersistenceSnapshot: Sendable {
  let planDisplayName: String
  let planTargetArrivalAt: Double
  let planDepartureAt: Double
  let destinationName: String
  let destinationAddress: String
  let planSourceVersion: Int?
  let targetArrivalValueSource: String
  let targetArrivalOverriddenAt: Double?
  let destinationValueSource: String
  let destinationOverriddenAt: Double?
  let linkOccurrenceID: String?
  let linkSourceVersion: Int?
  let reminderStatus: String
  let reminderFollowsSource: Bool
  let occurrenceTitle: String?
  let occurrenceLocation: String?
  let occurrenceState: String
  let occurrenceSourceVersion: Int
}

private nonisolated func rescanPersistedTripOccurrence(
  database: AppDatabase,
  ownerID: UUID,
  startsAt: Date,
  title: String,
  locationText: String
) async throws -> CalendarOccurrenceSummary {
  let repository = GRDBCalendarRepository(database: database)
  let window = CalendarScanWindow(
    displayStart: tripDate(2_000),
    displayEnd: tripDate(5_000),
    matchingStart: tripDate(1_500),
    matchingEnd: tripDate(6_000)
  )
  let scanID = UUID()
  try await repository.beginScan(
    ownerID: ownerID,
    scanID: scanID,
    window: window,
    startedAt: tripDate(1_100)
  )
  _ = try await repository.commitScan(
    CalendarScanCommit(
      scanID: scanID,
      ownerID: ownerID,
      window: window,
      occurrences: [
        SystemCalendarOccurrenceSnapshot(
          sourceExternalIdentityHMAC: Data(repeating: 0x82, count: 32),
          seriesExternalIdentityHMAC: Data(repeating: 0x93, count: 32),
          occurrenceExternalIdentityHMAC: Data(repeating: 0x92, count: 32),
          matchKeyHMAC: Data(repeating: 0x94, count: 32),
          sourceFingerprint: Data(repeating: 0x96, count: 32),
          hasRecurrence: false,
          isCancelled: false,
          isAllDay: false,
          startsAt: startsAt,
          endsAt: startsAt.addingTimeInterval(600),
          localStartDate: "2026-08-12",
          localEndDateExclusive: "2026-08-12",
          timeZoneIdentifier: "Asia/Shanghai",
          title: title,
          locationText: locationText
        )
      ],
      completedAt: tripDate(1_101)
    )
  )
  return try #require(
    try await repository.occurrences(
      ownerID: ownerID,
      from: window.displayStart,
      through: window.displayEnd
    ).first
  )
}

private nonisolated func makePersistedTripOccurrence(
  database: AppDatabase,
  ownerID: UUID,
  isAllDay: Bool
) async throws -> CalendarOccurrenceSummary {
  let repository = GRDBCalendarRepository(database: database)
  let sourceIdentity = Data(repeating: isAllDay ? 0x81 : 0x82, count: 32)
  let source = SystemCalendarSourceSnapshot(
    externalIdentityHMAC: sourceIdentity,
    title: "测试日历",
    kind: .caldav,
    isSubscribed: false,
    allowsContentModifications: true
  )
  let sourceID = try #require(
    try await repository.reconcileSources(
      ownerID: ownerID,
      snapshots: [source],
      observedAt: tripDate(800)
    ).first?.id
  )
  _ = try await repository.setSourceSelection(
    ownerID: ownerID,
    sourceID: sourceID,
    isSelected: true,
    changedAt: tripDate(801)
  )

  let window = CalendarScanWindow(
    displayStart: tripDate(2_000),
    displayEnd: tripDate(5_000),
    matchingStart: tripDate(1_500),
    matchingEnd: tripDate(6_000)
  )
  let scanID = UUID()
  try await repository.beginScan(
    ownerID: ownerID,
    scanID: scanID,
    window: window,
    startedAt: tripDate(900)
  )
  let occurrenceIdentity = Data(repeating: isAllDay ? 0x91 : 0x92, count: 32)
  _ = try await repository.commitScan(
    CalendarScanCommit(
      scanID: scanID,
      ownerID: ownerID,
      window: window,
      occurrences: [
        SystemCalendarOccurrenceSnapshot(
          sourceExternalIdentityHMAC: sourceIdentity,
          seriesExternalIdentityHMAC: Data(repeating: 0x93, count: 32),
          occurrenceExternalIdentityHMAC: occurrenceIdentity,
          matchKeyHMAC: Data(repeating: 0x94, count: 32),
          sourceFingerprint: Data(repeating: 0x95, count: 32),
          hasRecurrence: false,
          isCancelled: false,
          isAllDay: isAllDay,
          startsAt: tripDate(3_000),
          endsAt: tripDate(3_600),
          localStartDate: "2026-08-12",
          localEndDateExclusive: "2026-08-13",
          timeZoneIdentifier: "Asia/Shanghai",
          title: "日历会议",
          locationText: "合成会场"
        )
      ],
      completedAt: tripDate(901)
    )
  )
  return try #require(
    try await repository.occurrences(
      ownerID: ownerID,
      from: window.displayStart,
      through: window.displayEnd
    ).first
  )
}

private nonisolated func eventPlanSnapshot(
  database: AppDatabase,
  planID: UUID,
  occurrenceID: UUID
) async throws -> EventPlanPersistenceSnapshot {
  try await database.pool.read { database in
    let planRow = try Row.fetchOne(
      database,
      sql: """
        SELECT
          display_name,
          target_arrival_at,
          planned_departure_at,
          destination_snapshot_id,
          source_occurrence_version,
          target_arrival_value_source,
          target_arrival_user_overridden_at,
          destination_value_source,
          destination_user_overridden_at
        FROM trip_plans
        WHERE id = ?
        """,
      arguments: [planID.uuidString.lowercased()]
    )
    let plan = try #require(planRow)
    let destinationRow = try Row.fetchOne(
      database,
      sql: "SELECT name, address FROM location_snapshots WHERE id = ?",
      arguments: [plan["destination_snapshot_id"] as String]
    )
    let destination = try #require(destinationRow)
    let linkRow = try Row.fetchOne(
      database,
      sql: """
        SELECT calendar_occurrence_id, source_occurrence_version
        FROM event_trip_links
        WHERE trip_plan_id = ?
        """,
      arguments: [planID.uuidString.lowercased()]
    )
    let link = try #require(linkRow)
    let reminderRow = try Row.fetchOne(
      database,
      sql: """
        SELECT status, follows_source
        FROM departure_reminders
        WHERE trip_plan_id = ?
        """,
      arguments: [planID.uuidString.lowercased()]
    )
    let reminder = try #require(reminderRow)
    let occurrenceRow = try Row.fetchOne(
      database,
      sql: """
        SELECT title, location_text, source_state, source_version
        FROM calendar_occurrences
        WHERE id = ?
        """,
      arguments: [occurrenceID.uuidString.lowercased()]
    )
    let occurrence = try #require(occurrenceRow)
    let followsSource: Int = reminder["follows_source"]
    return EventPlanPersistenceSnapshot(
      planDisplayName: plan["display_name"],
      planTargetArrivalAt: plan["target_arrival_at"],
      planDepartureAt: plan["planned_departure_at"],
      destinationName: destination["name"],
      destinationAddress: destination["address"],
      planSourceVersion: plan["source_occurrence_version"],
      targetArrivalValueSource: plan["target_arrival_value_source"],
      targetArrivalOverriddenAt: plan["target_arrival_user_overridden_at"],
      destinationValueSource: plan["destination_value_source"],
      destinationOverriddenAt: plan["destination_user_overridden_at"],
      linkOccurrenceID: link["calendar_occurrence_id"],
      linkSourceVersion: link["source_occurrence_version"],
      reminderStatus: reminder["status"],
      reminderFollowsSource: followsSource == 1,
      occurrenceTitle: occurrence["title"],
      occurrenceLocation: occurrence["location_text"],
      occurrenceState: occurrence["source_state"],
      occurrenceSourceVersion: occurrence["source_version"]
    )
  }
}

private nonisolated func pendingRevisionCount(
  database: AppDatabase,
  occurrenceID: UUID
) async throws -> Int {
  try await database.pool.read { database in
    try Int.fetchOne(
      database,
      sql: """
        SELECT COUNT(*)
        FROM calendar_occurrence_revisions
        WHERE calendar_occurrence_id = ? AND resolution_state = 'pending'
        """,
      arguments: [occurrenceID.uuidString.lowercased()]
    ) ?? 0
  }
}

private nonisolated func makeTripIdentity(_ database: AppDatabase) throws
  -> LocalLedgerIdentity
{
  try LocalLedgerBootstrap(database: database).initializeIfNeeded(
    suggestedCurrencyCode: .cny,
    now: tripDate(100)
  )
}

private nonisolated func tripDate(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSince1970: seconds)
}

private nonisolated func makeTripLocation(
  byte: UInt8,
  name: String
) -> ConfirmedLocation {
  ConfirmedLocation(
    id: UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte)),
    name: name,
    address: "合成地址 \(byte)",
    latitude: 31.2 + Double(byte) / 10_000,
    longitude: 121.4 + Double(byte) / 10_000,
    source: .mapkit,
    horizontalAccuracy: nil
  )
}

private nonisolated func makeSaveRequest(
  planID: UUID = UUID(),
  ownerID: UUID,
  origin: ConfirmedLocation? = nil,
  destination: ConfirmedLocation,
  targetArrival: Date = tripDate(3_000),
  departure: Date = tripDate(2_000),
  route: RouteEstimateDraft? = nil,
  reminderEnabled: Bool,
  departureValueSource: TripPlanValueSource = .user,
  eventSource: TripPlanEventSource? = nil,
  targetArrivalValueSource: TripPlanValueSource = .user
) -> SaveTripPlanRequest {
  SaveTripPlanRequest(
    planID: planID,
    ownerID: ownerID,
    displayName: "合成计划",
    origin: origin,
    destination: destination,
    transportMode: .driving,
    targetArrivalAt: targetArrival,
    plannedDepartureAt: departure,
    timezoneIdentifier: "Asia/Shanghai",
    preparationBufferSeconds: 600,
    routeEstimate: route,
    eventSource: eventSource,
    displayNameValueSource: eventSource == nil ? .user : .event,
    destinationValueSource: .user,
    targetArrivalValueSource: targetArrivalValueSource,
    departureValueSource: departureValueSource,
    reminderEnabled: reminderEnabled,
    reminderFollowsSource: false,
    submittedAt: tripDate(1_000)
  )
}

private nonisolated func makeTripPlanningService(
  ownerID: UUID,
  repository: GRDBTripPlanRepository,
  reminder: FixedReminderService,
  navigation: FixedNavigationService,
  now: @escaping @Sendable () -> Date = { tripDate(1_000) }
) -> TripPlanningService {
  TripPlanningService(
    ownerID: ownerID,
    repository: repository,
    placeSearch: FixedPlaceSearchService(),
    routePlanning: FixedRoutePlanningService(),
    reminders: reminder,
    navigation: navigation,
    now: now
  )
}

private actor FixedReminderService: ReminderService {
  private let state: ReminderAuthorizationState
  private var requests: [ReminderScheduleRequest] = []

  init(state: ReminderAuthorizationState) {
    self.state = state
  }

  func authorizationState() async -> ReminderAuthorizationState { state }

  func requestAuthorization() async throws -> ReminderAuthorizationState { state }

  func schedule(_ request: ReminderScheduleRequest) async throws {
    requests.append(request)
  }

  func cancel(requestIdentifier: String) async {
    requests.removeAll { $0.requestIdentifier == requestIdentifier }
  }

  func scheduledRequests() -> [ReminderScheduleRequest] { requests }
}

private nonisolated struct FixedPlaceSearchService: PlaceSearchService {
  func search(query: String) async throws -> [PlaceCandidate] { [] }
}

private nonisolated struct FixedRoutePlanningService: RoutePlanningService {
  func route(for request: RoutePlanningRequest) async throws -> RouteEstimateDraft {
    throw TripPlanningError.routeUnavailable
  }
}

private actor SuccessfulJourneyLocationDriver: JourneyLocationDriver {
  private var handler: (@Sendable (JourneyLocationEvent) async -> Void)?

  func start(
    transportMode: TripTransportMode,
    handler: @escaping @Sendable (JourneyLocationEvent) async -> Void
  ) async throws {
    self.handler = handler
  }

  func stop() async {
    handler = nil
  }
}

@MainActor
private final class FixedNavigationService: ExternalNavigationService {
  private let didOpen: Bool

  init(didOpen: Bool) {
    self.didOpen = didOpen
  }

  func openAppleMaps(
    destination: ConfirmedLocation,
    transportMode: TripTransportMode
  ) async -> Bool {
    didOpen
  }
}

@MainActor
private final class RecordingDestinationClipboard: DestinationClipboard {
  private(set) var values: [String] = []

  func copy(_ text: String) {
    values.append(text)
  }
}
