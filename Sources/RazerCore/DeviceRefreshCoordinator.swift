import Foundation

/// Snapshot produced by a single refresh/reconnect attempt on the HID queue.
public struct DeviceRefreshSnapshot: Equatable, Sendable {
    public let state: DeviceState?
    public let probeReport: WheelCapabilityProbe.ProbeReport?
    public let becameConnected: Bool
    public let commandError: RazerCommandError?
    public let disconnected: Bool
    public let applyWarning: String?
    public let profileAppliedSuccessfully: Bool
    /// Apply generation whose result may update retry/baseline/warning state.
    public let applyGeneration: UInt64?
    /// Exact hardware snapshot that was written; never derived from a later selection.
    public let appliedHardwareSettings: HardwareProfileSettings?
    /// Authoritative auto-apply state after this refresh's transitions (HID-queue truth).
    public let autoApplyState: AutoApplyCoordinator.State
    /// True only when a verified/unverified apply outcome was committed under a still-current
    /// generation. False for superseded attempts, no attempt, or disconnected results (even though
    /// `autoApplyState` remains authoritative for disconnect resets via the disconnected branch).
    public let applyOutcomeCommitted: Bool

    public init(
        state: DeviceState?,
        probeReport: WheelCapabilityProbe.ProbeReport?,
        becameConnected: Bool,
        commandError: RazerCommandError?,
        disconnected: Bool,
        applyWarning: String?,
        profileAppliedSuccessfully: Bool,
        applyGeneration: UInt64?,
        appliedHardwareSettings: HardwareProfileSettings?,
        autoApplyState: AutoApplyCoordinator.State,
        applyOutcomeCommitted: Bool
    ) {
        self.state = state
        self.probeReport = probeReport
        self.becameConnected = becameConnected
        self.commandError = commandError
        self.disconnected = disconnected
        self.applyWarning = applyWarning
        self.profileAppliedSuccessfully = profileAppliedSuccessfully
        self.applyGeneration = applyGeneration
        self.appliedHardwareSettings = appliedHardwareSettings
        self.autoApplyState = autoApplyState
        self.applyOutcomeCommitted = applyOutcomeCommitted
    }
}

enum DeviceRefreshCancellation: Error, Equatable {
    case staleLifecycle
}

/// Inputs for one HID-queue refresh execution (snapshot of MainActor state at schedule time).
public struct DeviceRefreshRequest: Sendable {
    public let wasConnectedBefore: Bool
    public let selectedProfile: MouseProfile?
    public let shouldAutoApply: Bool
    public let autoApplySnapshot: AutoApplyCoordinator.State
    public let cachedWheelCapability: WheelHardwareCapability
    public let generationAtSchedule: UInt64
    public let lifecycleToken: DeviceLifecycleGate.Token

    public init(
        wasConnectedBefore: Bool,
        selectedProfile: MouseProfile?,
        shouldAutoApply: Bool,
        autoApplySnapshot: AutoApplyCoordinator.State,
        cachedWheelCapability: WheelHardwareCapability,
        generationAtSchedule: UInt64,
        lifecycleToken: DeviceLifecycleGate.Token
    ) {
        self.wasConnectedBefore = wasConnectedBefore
        self.selectedProfile = selectedProfile
        self.shouldAutoApply = shouldAutoApply
        self.autoApplySnapshot = autoApplySnapshot
        self.cachedWheelCapability = cachedWheelCapability
        self.generationAtSchedule = generationAtSchedule
        self.lifecycleToken = lifecycleToken
    }
}

/// Production refresh/reconnect flow. Owns auto-apply state transitions so AppModel
/// adopts HID-queue truth rather than re-deriving budget changes on the MainActor.
///
/// ## Disconnected / auto-apply semantics (per connected episode)
/// A refresh that ends `disconnected` applies `AutoApplyCoordinator.onDisconnect`
/// (`needsAutoApply = false`, `attemptsRemaining = max`). That ends the *current*
/// episode's arming. The next successful `becameConnected` + `onConnect` re-arms a
/// full budget for the *next* episode — this is the established per-connection model,
/// not a cross-cycle circuit breaker.
public enum DeviceRefreshCoordinator {
    /// Runs on the HID queue. On recoverable HID failures, clears the cached session
    /// and retries once with a fresh device open (sleep/wake / stale handle).
    public static func performRefresh(
        session: any DeviceSessionProtocol,
        request: DeviceRefreshRequest,
        applyGate: LatestHardwareApplyGate,
        lifecycleGate: DeviceLifecycleGate
    ) -> DeviceRefreshSnapshot? {
        let lifecycleToken = request.lifecycleToken
        guard lifecycleGate.isCurrentAndAwake(lifecycleToken) else { return nil }
        do {
            return try readRefreshSnapshot(
                session: session,
                request: request,
                forceReconnect: false,
                applyGate: applyGate,
                lifecycleGate: lifecycleGate
            )
        } catch DeviceRefreshCancellation.staleLifecycle {
            session.disconnect()
            return nil
        } catch let error as RazerCommandError {
            guard session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
                return nil
            }
            if error.shouldInvalidateSession {
                session.disconnect()
                guard lifecycleGate.isCurrentAndAwake(lifecycleToken) else { return nil }
                do {
                    return try readRefreshSnapshot(
                        session: session,
                        request: request,
                        forceReconnect: true,
                        applyGate: applyGate,
                        lifecycleGate: lifecycleGate
                    )
                } catch DeviceRefreshCancellation.staleLifecycle {
                    session.disconnect()
                    return nil
                } catch let retryError as RazerCommandError {
                    guard session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
                        return nil
                    }
                    session.disconnect()
                    return disconnectedSnapshot(
                        from: request.autoApplySnapshot,
                        commandError: retryError
                    )
                } catch {
                    guard session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
                        return nil
                    }
                    session.disconnect()
                    return disconnectedSnapshot(
                        from: request.autoApplySnapshot,
                        commandError: nil
                    )
                }
            }

            return disconnectedSnapshot(
                from: request.autoApplySnapshot,
                commandError: error
            )
        } catch {
            guard session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
                return nil
            }
            session.disconnect()
            return disconnectedSnapshot(
                from: request.autoApplySnapshot,
                commandError: nil
            )
        }
    }

    static func readRefreshSnapshot(
        session: any DeviceSessionProtocol,
        request: DeviceRefreshRequest,
        forceReconnect: Bool,
        applyGate: LatestHardwareApplyGate,
        lifecycleGate: DeviceLifecycleGate
    ) throws -> DeviceRefreshSnapshot {
        let lifecycleToken = request.lifecycleToken
        guard lifecycleGate.isCurrentAndAwake(lifecycleToken) else {
            throw DeviceRefreshCancellation.staleLifecycle
        }
        let client = forceReconnect
            ? try session.reconnectForRefresh()
            : try session.connectForRefresh()
        // Every post-connect/reconnect stale exit must retire the cached client.
        guard session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
            throw DeviceRefreshCancellation.staleLifecycle
        }
        let state = try client.readState()
        guard session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
            throw DeviceRefreshCancellation.staleLifecycle
        }
        let becameConnected = !request.wasConnectedBefore || forceReconnect
        var probeReport = becameConnected ? client.probeWheelCapability() : nil
        var effectiveWheelCapability = WheelCapabilityRefreshPolicy.resolvedCapability(
            fresh: probeReport?.capability,
            cached: request.cachedWheelCapability
        )
        guard session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
            throw DeviceRefreshCancellation.staleLifecycle
        }

        var applyState = request.autoApplySnapshot
        var applyOutcomeCommitted = false
        if becameConnected && request.shouldAutoApply {
            AutoApplyCoordinator.onConnect(autoReapplyEnabled: true, state: &applyState)
        }

        var applyWarning: String?
        var profileAppliedSuccessfully = false
        var applyGeneration: UInt64?
        var appliedHardwareSettings: HardwareProfileSettings?
        if AutoApplyCoordinator.shouldAttemptApply(
            state: applyState,
            autoReapplyEnabled: request.shouldAutoApply,
            hasProfile: request.selectedProfile != nil
        ),
           let profile = request.selectedProfile {
            applyGeneration = request.generationAtSchedule
            // Reprobe when requested wheel fields are still unknown — first connect or a later
            // retry with wasConnectedBefore true and an inconclusive cached capability.
            if probeReport == nil,
               WheelCapabilityRefreshPolicy.requiresProbe(
                   profile: profile,
                   capability: effectiveWheelCapability
               ) {
                probeReport = client.probeWheelCapability()
                effectiveWheelCapability = WheelCapabilityRefreshPolicy.resolvedCapability(
                    fresh: probeReport?.capability,
                    cached: request.cachedWheelCapability
                )
                guard session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
                    throw DeviceRefreshCancellation.staleLifecycle
                }
            }
            // Skip if a newer explicit/DPI/selection apply claimed the gate since scheduling.
            // Still connected with a valid lifecycle token for a read-only snapshot; only the
            // apply generation is stale. If lifecycle itself went stale, retire instead.
            // Superseded-before-write consumes no auto-apply attempt.
            guard lifecycleGate.isCurrentAndAwake(lifecycleToken) else {
                session.disconnect()
                throw DeviceRefreshCancellation.staleLifecycle
            }
            guard applyGate.isCurrent(request.generationAtSchedule) else {
                return DeviceRefreshSnapshot(
                    state: state,
                    probeReport: probeReport,
                    becameConnected: becameConnected,
                    commandError: nil,
                    disconnected: false,
                    applyWarning: nil,
                    profileAppliedSuccessfully: false,
                    applyGeneration: applyGeneration,
                    appliedHardwareSettings: nil,
                    autoApplyState: applyState,
                    applyOutcomeCommitted: false
                )
            }
            let settings = HardwareProfileSettings(profile: profile)
            do {
                let result = try session.applyForRefresh(
                    profile: profile,
                    to: client,
                    wheelCapability: effectiveWheelCapability,
                    isStillCurrent: {
                        applyGate.isCurrent(request.generationAtSchedule)
                            && lifecycleGate.isCurrentAndAwake(lifecycleToken)
                    }
                )
                guard session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
                    throw DeviceRefreshCancellation.staleLifecycle
                }
                // Generation stale after write: do not commit success/failure (session stays up).
                guard applyGate.isCurrent(request.generationAtSchedule) else {
                    return DeviceRefreshSnapshot(
                        state: state,
                        probeReport: probeReport,
                        becameConnected: becameConnected,
                        commandError: nil,
                        disconnected: false,
                        applyWarning: nil,
                        profileAppliedSuccessfully: false,
                        applyGeneration: applyGeneration,
                        appliedHardwareSettings: nil,
                        autoApplyState: applyState,
                        applyOutcomeCommitted: false
                    )
                }
                if let recorded = HardwareApplyBaseline.settingsToRecord(
                    result: result,
                    applied: settings
                ) {
                    profileAppliedSuccessfully = true
                    appliedHardwareSettings = recorded
                    AutoApplyCoordinator.onApplySuccess(&applyState)
                    applyOutcomeCommitted = true
                } else if let warning = result.verificationWarning {
                    applyWarning = warning
                    AutoApplyCoordinator.onApplyFailure(&applyState)
                    applyOutcomeCommitted = true
                }
            } catch {
                if HardwareApplyFailurePolicy.shouldInvalidate(error: error) {
                    // Invalidating failures rethrow into the one-retry / disconnect path.
                    // Do not consume an attempt here — reconnect may re-arm, and a final
                    // disconnect resets via onDisconnect.
                    throw error
                }
                applyWarning = error.localizedDescription
                AutoApplyCoordinator.onApplyFailure(&applyState)
                applyOutcomeCommitted = true
            }
        }

        guard session.retainIfLifecycleCurrent(lifecycleGate, token: lifecycleToken) else {
            throw DeviceRefreshCancellation.staleLifecycle
        }

        return DeviceRefreshSnapshot(
            state: state,
            probeReport: probeReport,
            becameConnected: becameConnected,
            commandError: nil,
            disconnected: false,
            applyWarning: applyWarning,
            profileAppliedSuccessfully: profileAppliedSuccessfully,
            applyGeneration: applyGeneration,
            appliedHardwareSettings: appliedHardwareSettings,
            autoApplyState: applyState,
            applyOutcomeCommitted: applyOutcomeCommitted
        )
    }

    /// Ends the current connected episode's auto-apply arming (`onDisconnect`).
    /// Does not commit a verified/unverified apply outcome.
    private static func disconnectedSnapshot(
        from prior: AutoApplyCoordinator.State,
        commandError: RazerCommandError?
    ) -> DeviceRefreshSnapshot {
        var state = prior
        AutoApplyCoordinator.onDisconnect(&state)
        return DeviceRefreshSnapshot(
            state: nil,
            probeReport: nil,
            becameConnected: false,
            commandError: commandError,
            disconnected: true,
            applyWarning: nil,
            profileAppliedSuccessfully: false,
            applyGeneration: nil,
            appliedHardwareSettings: nil,
            autoApplyState: state,
            applyOutcomeCommitted: false
        )
    }
}
