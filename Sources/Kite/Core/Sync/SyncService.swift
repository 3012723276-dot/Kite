import Combine
import Foundation

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService(defaults: .standard)

    @Published private(set) var enabled: Bool
    @Published private(set) var loginEnabled: Bool
    @Published private(set) var sessions: [SyncRecord<PlaybackCheckpoint>] = []
    @Published private(set) var logins: [SyncRecord<SyncedLogin>] = []
    @Published private(set) var loginKeyState: LoginSync.KeyState = .unset
    @Published private(set) var errorMessage: String?
    @Published private(set) var connected = false
    @Published private(set) var importingLogin = false
    @Published private(set) var resumingDeviceID: UUID?

    private let repository = SyncRepository()
    private let defaults: UserDefaults
    // Exists only after the persistent device identity has been loaded.
    private var revisionClock: SyncRevisionClock?
    private let deviceIdentity: @Sendable () async throws -> UUID
    private let playbackContext: @MainActor () -> (session: PlaybackSession?, accountID: Int?)
    private let periodicRefreshSleep: @Sendable () async throws -> Void
    private let deviceName: String
    private let preferencesSync: PreferencesSync
    private let loginSync: LoginSync
    private var lastPublishedPlayback: PlaybackSession?
    private var hasPublishedPlayback = false
    private var subscriptions: Set<AnyCancellable> = []
    private var periodicRefreshTask: Task<Void, Never>?
    private var coalescingTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var connectionID = UUID()
    private var resumeRequestID = UUID()
    private var started = false
    private var foreground = true
    private struct SyncRequest {
        var refreshDomains: Set<SyncRepository.Domain> = []
        var publicationDomains: Set<SyncRepository.Domain> = []
        var isEmpty: Bool { refreshDomains.isEmpty && publicationDomains.isEmpty }

        mutating func formUnion(_ other: Self) {
            refreshDomains.formUnion(other.refreshDomains)
            publicationDomains.formUnion(other.publicationDomains)
        }
    }
    private var pendingSyncRequest = SyncRequest()

    private enum Keys {
        static let enabled = "sync.enabled"
        static let login = "sync.publishLogin"
        static let bookmark = "sync.directoryBookmark"
        static let identity = "sync.iCloudIdentity"
    }

    init(
        defaults: UserDefaults,
        deviceIdentity: @escaping @Sendable () async throws -> UUID = {
            try await SyncDeviceIdentity.load()
        },
        playbackContext: @escaping @MainActor () -> (session: PlaybackSession?, accountID: Int?) = {
            (PlayerService.shared.playbackSession, AccountStore.shared.authenticatedAccountID)
        },
        periodicRefreshSleep: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(20))
        },
        loginKeyStore: LoginKeyStore = .keychain
    ) {
        self.defaults = defaults
        loginSync = LoginSync(keyStore: loginKeyStore)
        self.deviceIdentity = deviceIdentity
        self.playbackContext = playbackContext
        self.periodicRefreshSleep = periodicRefreshSleep
        enabled = defaults.bool(forKey: Keys.enabled)
        loginEnabled = defaults.bool(forKey: Keys.login)
        #if os(iOS)
            deviceName = UIDevice.current.name
        #else
            deviceName = Host.current().localizedName ?? "Mac"
        #endif
        preferencesSync = PreferencesSync(defaults: defaults, settings: .shared)
        do {
            try preferencesSync.restore()
        } catch { errorMessage = error.localizedDescription }
    }

    deinit {
        periodicRefreshTask?.cancel()
        coalescingTask?.cancel()
        syncTask?.cancel()
    }

    func start() async {
        guard !started else { return }
        started = true
        NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.disconnectChangedIdentity() }
            }.store(in: &subscriptions)
        let player = PlayerService.shared
        var playbackChanges = [
            player.$currentTrack.map { _ in () }.eraseToAnyPublisher(),
            player.$queue.map { _ in () }.eraseToAnyPublisher(),
            player.$shuffledQueue.map { _ in () }.eraseToAnyPublisher(),
            player.$playNextList.map { _ in () }.eraseToAnyPublisher(),
            player.$currentIndex.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$source.map { _ in () }.eraseToAnyPublisher(),
            player.$repeatMode.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$isFMMode.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]
        #if os(macOS)
            playbackChanges.append(player.$queueOrder.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
            playbackChanges.append(player.$autoMixQueue.map { _ in () }.eraseToAnyPublisher())
        #else
            playbackChanges.append(player.$shuffleEnabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
        #endif
        let account = AccountStore.shared
        Publishers.MergeMany(playbackChanges).sink { [weak self] in
            self?.scheduleSync(SyncRequest(publicationDomains: [.playback]))
        }.store(in: &subscriptions)
        player.$isPlaying.removeDuplicates().sink { [weak self] isPlaying in
            self?.updatePeriodicRefreshTask(isPlaying: isPlaying)
            self?.scheduleSync(SyncRequest(publicationDomains: [.playback]))
        }.store(in: &subscriptions)
        SettingsManager.shared.syncPreferenceChanges.sink { [weak self] in
            self?.scheduleSync(SyncRequest(publicationDomains: [.preferences]))
        }.store(in: &subscriptions)
        Publishers.MergeMany([
            account.$profile.map { _ in () }.eraseToAnyPublisher(),
            account.$isBootstrapped.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]).sink { [weak self] in
            self?.scheduleSync(SyncRequest(publicationDomains: [.login, .playback]))
        }.store(in: &subscriptions)
        guard enabled else { return }
        if await disconnectChangedIdentity() { return }
        do { _ = try await enable() } catch is CancellationError { return } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Returns false when directory authorization is needed. The caller presents
    /// the platform picker directly, without a second confirmation screen.
    func enable() async throws -> Bool {
        let previousConnectionID = invalidateConnection()
        let activeConnectionID = connectionID
        do {
            await repository.disconnect(connectionID: previousConnectionID)
            guard connectionID == activeConnectionID else { throw CancellationError() }
            let identity = try await deviceIdentity()
            guard connectionID == activeConnectionID else { throw CancellationError() }
            revisionClock = SyncRevisionClock(defaults: defaults, deviceID: identity, deviceName: deviceName)
            if let bookmark = defaults.data(forKey: Keys.bookmark) {
                let refreshed = try await repository.restore(bookmark: bookmark, connectionID: activeConnectionID)
                guard connectionID == activeConnectionID else { throw CancellationError() }
                defaults.set(refreshed, forKey: Keys.bookmark)
            } else if try await !repository.connectContainer(connectionID: activeConnectionID) {
                guard connectionID == activeConnectionID else { throw CancellationError() }
                return false
            }
            try await activateConnection(activeConnectionID)
            return true
        } catch {
            guard connectionID == activeConnectionID else { throw CancellationError() }
            connected = false
            throw error
        }
    }

    func connect(to directory: URL) async {
        let previousConnectionID = invalidateConnection()
        let activeConnectionID = connectionID
        do {
            await repository.disconnect(connectionID: previousConnectionID)
            guard connectionID == activeConnectionID else { return }
            let identity = try await deviceIdentity()
            guard connectionID == activeConnectionID else { return }
            revisionClock = SyncRevisionClock(defaults: defaults, deviceID: identity, deviceName: deviceName)
            let bookmark = try await repository.connect(to: directory, connectionID: activeConnectionID)
            guard connectionID == activeConnectionID else { return }
            defaults.set(bookmark, forKey: Keys.bookmark)
            try await activateConnection(activeConnectionID)
        } catch {
            guard connectionID == activeConnectionID else { return }
            connected = false
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func disable() async -> Bool {
        let previousConnectionID = invalidateConnection()
        let disabledConnectionID = connectionID
        enabled = false
        defaults.set(false, forKey: Keys.enabled)
        await repository.disconnect(connectionID: previousConnectionID)
        return connectionID == disabledConnectionID
    }

    /// Invalidates results before awaiting repository teardown. Old tasks cannot
    /// clear a replacement connection's work when they eventually return.
    private func invalidateConnection() -> UUID {
        let previousConnectionID = connectionID
        connectionID = UUID()
        connected = false
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        coalescingTask?.cancel()
        coalescingTask = nil
        syncTask?.cancel()
        syncTask = nil
        pendingSyncRequest = SyncRequest()
        resumeRequestID = UUID()
        resumingDeviceID = nil
        sessions = []
        logins = []
        revisionClock = nil
        preferencesSync.resetConnection()
        loginSync.resetConnection()
        loginKeyState = .unset
        lastPublishedPlayback = nil
        hasPublishedPlayback = false
        errorMessage = nil
        return previousConnectionID
    }

    /// A connection owns its observers and publication checkpoints. Both restored
    /// authorization and a newly selected folder enter through this same boundary.
    private func activateConnection(_ connectionID: UUID) async throws {
        guard self.connectionID == connectionID else { throw CancellationError() }
        try rememberIdentity()
        connected = true
        enabled = true
        defaults.set(true, forKey: Keys.enabled)
        updatePeriodicRefreshTask(isPlaying: PlayerService.shared.isPlaying)
        await observeDirectory()
        guard self.connectionID == connectionID, enabled else { throw CancellationError() }
        await synchronizeNow()
        guard self.connectionID == connectionID, enabled else { throw CancellationError() }
    }

    func setForeground(_ active: Bool) async {
        foreground = active
        updatePeriodicRefreshTask(isPlaying: PlayerService.shared.isPlaying)
        guard enabled, connected else { return }
        await synchronizeNow()
    }

    func setLoginEnabled(_ enabled: Bool) async {
        loginEnabled = enabled
        defaults.set(enabled, forKey: Keys.login)
        await synchronizeNow(refreshing: [.login], publishing: [.login])
    }

    /// Revoke unless login sharing is on and another device still offers this
    /// account: its session may be in use there. The last device out revokes.
    func shouldRevokeLoginSession(accountID: Int?) -> Bool {
        guard enabled, loginEnabled, let accountID, let revisionClock else { return true }
        return !loginSync.isAccountSharedElsewhere(accountID: accountID, deviceID: revisionClock.deviceID)
    }

    func unlockLogin(passphrase: String) async throws {
        guard enabled, connected else { throw SyncError.unavailable }
        let connection = connectionID
        try await loginSync.unlock(passphrase: passphrase)
        guard connection == connectionID else { throw CancellationError() }
        loginKeyState = loginSync.keyState
        await synchronizeNow(refreshing: [.login], publishing: [.login])
    }

    /// Sets a new sync passphrase for the folder. Every other device must enter
    /// it before it can share or receive a login again.
    func createLoginKey(passphrase: String, confirmation: String) async throws {
        guard passphrase == confirmation else { throw SyncError.passphraseMismatch }
        guard enabled, connected else { throw SyncError.unavailable }
        let connection = connectionID
        try await loginSync.createKey(passphrase: passphrase, repository: repository, connectionID: connection)
        guard connection == connectionID else { throw CancellationError() }
        loginKeyState = loginSync.keyState
        await synchronizeNow(refreshing: [.login], publishing: [.login])
    }

    func resume(_ record: SyncRecord<PlaybackCheckpoint>) async throws {
        guard enabled, connected else { throw SyncError.unavailable }
        guard let checkpoint = record.payload else { throw SyncError.invalidRecord }
        guard let accountID = AccountStore.shared.authenticatedAccountID,
            checkpoint.accountID == accountID
        else { throw SyncError.accountMismatch }
        guard resumingDeviceID != record.id else { return }
        let connection = connectionID
        let request = UUID()
        resumeRequestID = request
        resumingDeviceID = record.id
        defer { if resumeRequestID == request { resumingDeviceID = nil } }
        let session: PlaybackSession
        do { session = try await repository.loadPlayback(record, connectionID: connection) } catch {
            guard enabled, connected, connection == connectionID, resumeRequestID == request else {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
        guard enabled, connected, connection == connectionID, resumeRequestID == request,
            AccountStore.shared.authenticatedAccountID == accountID,
            sessions.contains(where: { $0.id == record.id && $0.payload?.accountID == accountID })
        else { throw CancellationError() }
        try PlayerService.shared.resume(session)
    }

    @discardableResult
    func importLogin(_ record: SyncRecord<SyncedLogin>) async throws -> Bool {
        guard !importingLogin else { return false }
        let connection = connectionID
        importingLogin = true
        defer { importingLogin = false }
        guard let login = record.payload else { throw SyncError.invalidRecord }
        // A withdrawn or disconnected offer is stale, not locked.
        guard enabled, connected, connectionID == connection,
              logins.contains(where: { $0.revision == record.revision }) else { throw CancellationError() }
        let cookies = try loginSync.open(login)
        try await AccountStore.shared.importLogin(
            accountID: login.accountID, cookies: cookies,
            authorization: {
                self.enabled && self.connected && self.connectionID == connection
                    && AccountStore.shared.isBootstrapped && AccountStore.shared.authenticatedAccountID == nil
                    && self.logins.contains { $0.revision == record.revision }
            })
        try Task.checkCancellation()
        guard enabled, connected, connection == connectionID,
            AccountStore.shared.authenticatedAccountID == login.accountID
        else { throw CancellationError() }
        // Receiving a login also authorizes this device to share it back.
        // Commit consent only after verification and credential persistence.
        loginEnabled = true
        defaults.set(true, forKey: Keys.login)
        await synchronizeNow(refreshing: [.login], publishing: [.login, .playback])
        await AccountStore.shared.refreshLibrary()
        return AccountStore.shared.authenticatedAccountID == login.accountID
    }

    /// Refreshes may merge and publish domain state. Bypasses the coalescing window
    /// and waits for the shared sync task to finish.
    func synchronizeNow(
        refreshing: Set<SyncRepository.Domain> = Set(SyncRepository.Domain.allCases),
        publishing: Set<SyncRepository.Domain> = Set(SyncRepository.Domain.allCases)
    ) async {
        guard enabled, connected else { return }
        pendingSyncRequest.formUnion(SyncRequest(refreshDomains: refreshing, publicationDomains: publishing))
        coalescingTask?.cancel()
        coalescingTask = nil
        await ensureSyncTask()?.value
    }

    private func scheduleSync(_ request: SyncRequest) {
        guard enabled, connected else { return }
        pendingSyncRequest.formUnion(request)
        guard syncTask == nil, coalescingTask == nil else { return }
        let scheduledConnectionID = connectionID
        // A bounded window coalesces bursts without starving continuous changes.
        coalescingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self, self.connectionID == scheduledConnectionID else { return }
            self.coalescingTask = nil
            self.ensureSyncTask()
        }
    }

    /// Reuses the active task, or starts one when the connection has pending work.
    @discardableResult
    private func ensureSyncTask() -> Task<Void, Never>? {
        guard enabled, connected, let revisionClock else { return nil }
        if let syncTask { return syncTask }
        guard !pendingSyncRequest.isEmpty else { return nil }
        let activeConnectionID = connectionID
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionID == activeConnectionID {
                    self.syncTask = nil
                }
            }
            while self.enabled, self.connected, self.connectionID == activeConnectionID, !Task.isCancelled {
                let currentRequest = self.pendingSyncRequest
                self.pendingSyncRequest = SyncRequest()
                let retryRequest = await self.synchronizeDomains(
                    currentRequest, connectionID: activeConnectionID, clock: revisionClock)
                guard self.connectionID == activeConnectionID, !Task.isCancelled else { return }
                let hasNewRequests = !self.pendingSyncRequest.isEmpty
                self.pendingSyncRequest.formUnion(retryRequest)
                // Failures wait for another event or the periodic refresh; do not
                // spin on a missing cloud file. Changes received during I/O drain now.
                if !hasNewRequests { return }
            }
        }
        return syncTask
    }

    private func synchronizeDomains(
        _ request: SyncRequest, connectionID: UUID, clock: SyncRevisionClock
    ) async -> SyncRequest {
        var retryRequest = SyncRequest()
        var failures: [Error] = []
        for domain in SyncRepository.Domain.allCases
        where request.refreshDomains.contains(domain) || request.publicationDomains.contains(domain) {
            guard enabled, connected, self.connectionID == connectionID, !Task.isCancelled else { return SyncRequest() }
            do {
                switch domain {
                case .preferences:
                    try await preferencesSync.synchronize(
                        reading: request.refreshDomains.contains(domain),
                        repository: repository, connectionID: connectionID, clock: clock)
                case .playback:
                    try await synchronizePlayback(
                        refreshing: request.refreshDomains.contains(domain),
                        publishing: request.publicationDomains.contains(domain), connectionID: connectionID, clock: clock)
                case .login:
                    if request.refreshDomains.contains(domain) {
                        try await loginSync.read(repository: repository, connectionID: connectionID, clock: clock)
                        try Task.checkCancellation()
                    }
                    // Read consent after repository I/O, not before it suspends.
                    let incomingLogins = try await loginSync.publish(
                        enabled: loginEnabled,
                        repository: repository, connectionID: connectionID, clock: clock)
                    try Task.checkCancellation()
                    if loginKeyState != loginSync.keyState { loginKeyState = loginSync.keyState }
                    if !logins.elementsEqual(incomingLogins, by: { $0.revision == $1.revision }) { logins = incomingLogins }
                }
            } catch {
                guard enabled, connectionID == self.connectionID else { return SyncRequest() }
                retryRequest.refreshDomains.insert(domain)
                retryRequest.publicationDomains.insert(domain)
                if domain == .login, !logins.isEmpty { logins = [] }
                failures.append(error)
            }
        }
        guard enabled, connected, self.connectionID == connectionID, !Task.isCancelled else { return SyncRequest() }
        let message =
            failures.isEmpty ? nil : Set(failures.map(\.localizedDescription)).sorted().joined(separator: "\n")
        if failures.contains(where: {
            if case SyncError.unavailable = $0 { return true }
            return false
        }) {
            let previousConnectionID = invalidateConnection()
            errorMessage = message
            await repository.disconnect(connectionID: previousConnectionID)
            return SyncRequest()
        }
        if errorMessage != message { errorMessage = message }
        return retryRequest
    }

    private func synchronizePlayback(
        refreshing shouldRefreshPlayback: Bool, publishing shouldPublishPlayback: Bool,
        connectionID: UUID, clock: SyncRevisionClock
    ) async throws {
        try Task.checkCancellation()
        if shouldRefreshPlayback {
            let receivedPlayback = try await repository.readPlayback(connectionID: connectionID)
            try Task.checkCancellation()
            let records = receivedPlayback.records
            clock.observe(receivedPlayback.counter)
            clock.persistCounter()
            hasPublishedPlayback = records.contains { $0.id == clock.deviceID && $0.payload != nil }
            let incomingSessions = records.filter { $0.id != clock.deviceID && $0.payload != nil }
                .sorted { $0.updatedAt > $1.updatedAt }
            if !sessions.elementsEqual(incomingSessions, by: { $0.revision == $1.revision }) { sessions = incomingSessions }
        }
        if shouldPublishPlayback {
            let currentPlayback = playbackContext()
            if let session = currentPlayback.session,
                let accountID = currentPlayback.accountID, accountID > 0, session.accountID == accountID
            {
                if !hasPublishedPlayback || session.progress != lastPublishedPlayback?.progress || session != lastPublishedPlayback {
                    let record = try clock.makeRecord(session)
                    try await repository.writePlayback(record, connectionID: connectionID)
                    try Task.checkCancellation()
                    lastPublishedPlayback = session
                    hasPublishedPlayback = true
                }
            } else if hasPublishedPlayback {
                let tombstone: SyncRecord<PlaybackSession> = try clock.makeRecord(nil)
                try await repository.writePlayback(tombstone, connectionID: connectionID)
                try Task.checkCancellation()
                lastPublishedPlayback = nil
                hasPublishedPlayback = false
            }
        }
    }

    // The event value is used directly: @Published emits before isPlaying changes.
    func updatePeriodicRefreshTask(isPlaying: Bool) {
        guard foreground || isPlaying, enabled, connected else {
            periodicRefreshTask?.cancel()
            periodicRefreshTask = nil
            return
        }
        guard periodicRefreshTask == nil else { return }
        let activeConnectionID = connectionID
        let sleep = periodicRefreshSleep
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep() } catch { return }
                guard !Task.isCancelled, let self, self.enabled, self.connected,
                    self.connectionID == activeConnectionID
                else { return }
                await self.synchronizeNow()
                guard self.connectionID == activeConnectionID else { return }
            }
        }
    }

    private func observeDirectory() async {
        let activeConnectionID = connectionID
        await repository.observeChanges { [weak self] url in
            Task { @MainActor in
                guard let self, self.enabled, self.connected, self.connectionID == activeConnectionID,
                    self.foreground || PlayerService.shared.isPlaying
                else { return }
                let affectedDomains: Set<SyncRepository.Domain>
                if url.lastPathComponent == "Queues" || url.deletingLastPathComponent().lastPathComponent == "Queues" {
                    affectedDomains = [.playback]
                } else if let domain = SyncRepository.Domain(rawValue: url.deletingPathExtension().lastPathComponent) {
                    affectedDomains = [domain]
                } else {
                    affectedDomains = Set(SyncRepository.Domain.allCases)
                }
                self.scheduleSync(SyncRequest(refreshDomains: affectedDomains))
            }
        }
    }

    private func rememberIdentity() throws {
        if let token = FileManager.default.ubiquityIdentityToken {
            defaults.set(
                try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false),
                forKey: Keys.identity)
        } else {
            defaults.removeObject(forKey: Keys.identity)
        }
    }

    @discardableResult
    private func disconnectChangedIdentity() async -> Bool {
        guard let saved = defaults.data(forKey: Keys.identity) else { return false }
        do {
            // Apple's opaque identity token promises NSCoding, not NSSecureCoding.
            // Only decode this app's locally archived token, never repository data.
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: saved)
            unarchiver.requiresSecureCoding = false
            defer { unarchiver.finishDecoding() }
            guard let previous = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObjectProtocol
            else {
                throw SyncError.invalidRecord
            }
            if let current = FileManager.default.ubiquityIdentityToken, previous.isEqual(current) { return false }
            guard await disable() else { return false }
            loginEnabled = false
            defaults.set(false, forKey: Keys.login)
            defaults.removeObject(forKey: Keys.bookmark)
            defaults.removeObject(forKey: Keys.identity)
            errorMessage = SyncError.identityChanged.localizedDescription
            return true
        } catch {
            guard await disable() else { return false }
            errorMessage = error.localizedDescription
            return true
        }
    }
}
