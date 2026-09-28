import XCTest
@testable import DorsoCore

/// The light boost drives a full-screen overlay and the user's display
/// brightness on a timer, so the scheduling and the evening cutoff are the two
/// things that must not be wrong. Everything here runs against an injected
/// clock in a fixed time zone.
final class LightBoostEngineTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(hour: Int, minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 10,
            hour: hour, minute: minute, second: second
        ))!
    }

    private func makeConfig(
        autoInterval: TimeInterval = 15 * 60,
        duration: TimeInterval = 180,
        cutoffHour: Int = 20,
        isAutoEnabled: Bool = true
    ) -> LightBoostConfig {
        LightBoostConfig(
            isEnabled: true,
            isAutoEnabled: isAutoEnabled,
            autoInterval: autoInterval,
            duration: duration,
            peakIntensity: 0.18,
            cutoffHour: cutoffHour,
            startHour: 5,
            taper: 60 * 60,
            rampUp: 30,
            rampDown: 20,
            boostBrightness: false
        )
    }

    // MARK: - Evening cutoff

    func testFullStrengthDuringTheDay() {
        let scale = LightBoostEngine.daylightScale(at: date(hour: 11), config: makeConfig(), calendar: calendar)
        XCTAssertEqual(scale, 1.0, accuracy: 0.0001)
    }

    func testZeroAfterCutoff() {
        let scale = LightBoostEngine.daylightScale(at: date(hour: 20, minute: 1), config: makeConfig(), calendar: calendar)
        XCTAssertEqual(scale, 0)
    }

    func testZeroBeforeStartHour() {
        let scale = LightBoostEngine.daylightScale(at: date(hour: 3), config: makeConfig(), calendar: calendar)
        XCTAssertEqual(scale, 0)
    }

    func testTapersAcrossTheHourBeforeCutoff() {
        let config = makeConfig()
        let halfway = LightBoostEngine.daylightScale(at: date(hour: 19, minute: 30), config: config, calendar: calendar)
        XCTAssertEqual(halfway, 0.5, accuracy: 0.01)

        let nearlyOff = LightBoostEngine.daylightScale(at: date(hour: 19, minute: 54), config: config, calendar: calendar)
        XCTAssertEqual(nearlyOff, 0.1, accuracy: 0.01)
    }

    func testCustomCutoffHourIsRespected() {
        let config = makeConfig(cutoffHour: 17)
        XCTAssertEqual(LightBoostEngine.daylightScale(at: date(hour: 15), config: config, calendar: calendar), 1.0, accuracy: 0.0001)
        XCTAssertEqual(LightBoostEngine.daylightScale(at: date(hour: 17, minute: 30), config: config, calendar: calendar), 0)
    }

    /// A cutoff before the start hour leaves no valid window. Refusing beats
    /// guessing, because the wrong guess runs bright cyan overnight.
    func testCutoffAtOrBeforeStartHourDisablesEverything() {
        var config = makeConfig()
        config.startHour = 20
        config.cutoffHour = 8
        XCTAssertEqual(LightBoostEngine.daylightScale(at: date(hour: 22), config: config, calendar: calendar), 0)
        XCTAssertFalse(LightBoostEngine.isWithinActiveWindow(at: date(hour: 22), config: config, calendar: calendar))
    }

    // MARK: - Manual boosts

    func testManualBoostStartsDuringTheDay() {
        var engine = LightBoostEngine()
        XCTAssertTrue(engine.start(trigger: .manual, at: date(hour: 11), config: makeConfig(), calendar: calendar))
        XCTAssertTrue(engine.isBoosting)
    }

    /// The cutoff governs the unattended timer, not the button. Someone who
    /// deliberately asks for a boost at 11pm gets one, at full strength.
    func testManualBoostStillRunsAfterCutoff() {
        var engine = LightBoostEngine()
        let config = makeConfig()
        let late = date(hour: 22)
        XCTAssertTrue(engine.start(trigger: .manual, at: late, config: config, calendar: calendar))

        let holding = engine.tick(at: late.addingTimeInterval(90), config: config, calendar: calendar)
        XCTAssertEqual(holding.intensity, config.peakIntensity, accuracy: 0.001)
    }

    func testAutomaticBoostStillBlockedAfterCutoff() {
        var engine = LightBoostEngine()
        XCTAssertFalse(engine.start(trigger: .automatic, at: date(hour: 22), config: makeConfig(), calendar: calendar))
        XCTAssertFalse(engine.isBoosting)
    }

    /// A manual boost during the evening taper must not be dimmed by it.
    func testManualBoostIgnoresTheTaper() {
        var engine = LightBoostEngine()
        let config = makeConfig()
        let dusk = date(hour: 19, minute: 30)
        engine.start(trigger: .manual, at: dusk, config: config, calendar: calendar)

        let holding = engine.tick(at: dusk.addingTimeInterval(90), config: config, calendar: calendar)
        XCTAssertEqual(holding.intensity, config.peakIntensity, accuracy: 0.001)
    }

    func testAutomaticBoostIsDimmedByTheTaper() {
        var engine = LightBoostEngine()
        let config = makeConfig()
        let dusk = date(hour: 19, minute: 30)
        engine.start(trigger: .automatic, at: dusk, config: config, calendar: calendar)

        let holding = engine.tick(at: dusk.addingTimeInterval(90), config: config, calendar: calendar)
        XCTAssertEqual(holding.intensity, config.peakIntensity * 0.5, accuracy: 0.005)
    }

    func testIsAfterCutoffTracksTheAutomaticWindow() {
        XCTAssertFalse(LightBoostEngine.isAfterCutoff(at: date(hour: 11), config: makeConfig(), calendar: calendar))
        XCTAssertTrue(LightBoostEngine.isAfterCutoff(at: date(hour: 21), config: makeConfig(), calendar: calendar))
    }

    func testManualBoostRefusedWhenFeatureDisabled() {
        var config = makeConfig()
        config.isEnabled = false
        var engine = LightBoostEngine()
        XCTAssertFalse(engine.start(trigger: .manual, at: date(hour: 11), config: config, calendar: calendar))
    }

    func testSecondStartIsIgnoredWhileBoosting() {
        var engine = LightBoostEngine()
        let config = makeConfig()
        XCTAssertTrue(engine.start(trigger: .manual, at: date(hour: 11), config: config, calendar: calendar))
        XCTAssertFalse(engine.start(trigger: .manual, at: date(hour: 11, minute: 1), config: config, calendar: calendar))
    }

    // MARK: - Curve

    func testIntensityRampsUpHoldsAndFadesOut() {
        var engine = LightBoostEngine()
        let config = makeConfig(duration: 180)
        let start = date(hour: 11)
        engine.start(trigger: .manual, at: start, config: config, calendar: calendar)

        let atStart = engine.tick(at: start, config: config, calendar: calendar).intensity
        XCTAssertEqual(atStart, 0, accuracy: 0.001)

        let midRamp = engine.tick(at: start.addingTimeInterval(15), config: config, calendar: calendar).intensity
        XCTAssertGreaterThan(midRamp, 0)
        XCTAssertLessThan(midRamp, config.peakIntensity)

        let holding = engine.tick(at: start.addingTimeInterval(90), config: config, calendar: calendar).intensity
        XCTAssertEqual(holding, config.peakIntensity, accuracy: 0.001)

        let fading = engine.tick(at: start.addingTimeInterval(172), config: config, calendar: calendar).intensity
        XCTAssertGreaterThan(fading, 0)
        XCTAssertLessThan(fading, config.peakIntensity)
    }

    func testPhaseReportsRampHoldAndFade() {
        var engine = LightBoostEngine()
        let config = makeConfig(duration: 180)
        let start = date(hour: 11)
        engine.start(trigger: .manual, at: start, config: config, calendar: calendar)

        XCTAssertEqual(engine.phase(at: start.addingTimeInterval(5), config: config), .ramping)
        XCTAssertEqual(engine.phase(at: start.addingTimeInterval(90), config: config), .holding)
        XCTAssertEqual(engine.phase(at: start.addingTimeInterval(170), config: config), .fading)
        XCTAssertEqual(engine.phase(at: start.addingTimeInterval(200), config: config), .idle)
    }

    func testBoostEndsAfterItsDuration() {
        var engine = LightBoostEngine()
        let config = makeConfig(duration: 180)
        let start = date(hour: 11)
        engine.start(trigger: .manual, at: start, config: config, calendar: calendar)

        let result = engine.tick(at: start.addingTimeInterval(181), config: config, calendar: calendar)
        XCTAssertTrue(result.didEnd)
        XCTAssertFalse(engine.isBoosting)
        XCTAssertEqual(result.intensity, 0)
    }

    /// Short durations must not ramp up and down at the same time.
    func testShortDurationClampsRamps() {
        let config = makeConfig(duration: 30)
        let peak = LightBoostEngine.rawIntensity(elapsed: 15, config: config, duration: 30)
        XCTAssertEqual(peak, config.peakIntensity, accuracy: 0.001)
    }

    // MARK: - Automatic scheduling

    func testAutomaticBoostFiresOnlyAfterTheInterval() {
        var engine = LightBoostEngine()
        let config = makeConfig(autoInterval: 15 * 60)
        let start = date(hour: 9)
        engine.startAutoClock(at: start)

        XCTAssertFalse(engine.tick(at: start.addingTimeInterval(14 * 60), config: config, calendar: calendar).didStart)
        XCTAssertFalse(engine.isBoosting)

        let due = engine.tick(at: start.addingTimeInterval(15 * 60), config: config, calendar: calendar)
        XCTAssertTrue(due.didStart)
        XCTAssertTrue(engine.isBoosting)
    }

    func testAutomaticBoostDoesNotFireWithoutARunningClock() {
        var engine = LightBoostEngine()
        let config = makeConfig()
        let start = date(hour: 9)
        // No startAutoClock: the user isn't at their desk.
        XCTAssertFalse(engine.tick(at: start.addingTimeInterval(60 * 60), config: config, calendar: calendar).didStart)
    }

    func testAutomaticBoostRespectsDisabledAutoSetting() {
        var engine = LightBoostEngine()
        let config = makeConfig(isAutoEnabled: false)
        let start = date(hour: 9)
        engine.startAutoClock(at: start)
        XCTAssertFalse(engine.tick(at: start.addingTimeInterval(30 * 60), config: config, calendar: calendar).didStart)
    }

    /// The gap is measured from the end of one boost, not the start, so a long
    /// boost doesn't eat into the following interval.
    func testIntervalIsMeasuredFromTheEndOfThePreviousBoost() {
        var engine = LightBoostEngine()
        let config = makeConfig(autoInterval: 15 * 60, duration: 180)
        let start = date(hour: 9)
        engine.startAutoClock(at: start)

        let firstStart = start.addingTimeInterval(15 * 60)
        XCTAssertTrue(engine.tick(at: firstStart, config: config, calendar: calendar).didStart)

        let ended = firstStart.addingTimeInterval(180)
        XCTAssertTrue(engine.tick(at: ended, config: config, calendar: calendar).didEnd)

        // 15 minutes after the *start* of the last boost is too early.
        XCTAssertFalse(engine.tick(at: firstStart.addingTimeInterval(15 * 60), config: config, calendar: calendar).didStart)
        XCTAssertTrue(engine.tick(at: ended.addingTimeInterval(15 * 60), config: config, calendar: calendar).didStart)
    }

    /// Without this, every tick after the cutoff stays "due" and the first
    /// moment of the next morning fires a boost instantly.
    func testBlockedAutomaticBoostStillRestartsTheWait() {
        var engine = LightBoostEngine()
        let config = makeConfig(autoInterval: 15 * 60)
        let evening = date(hour: 21)
        engine.startAutoClock(at: evening)

        let attempt = engine.tick(at: evening.addingTimeInterval(15 * 60), config: config, calendar: calendar)
        XCTAssertFalse(attempt.didStart)
        XCTAssertEqual(engine.autoClockStartedAt, evening.addingTimeInterval(15 * 60))
    }

    // MARK: - Suspension

    func testPausingCancelsARunningBoost() {
        var engine = LightBoostEngine()
        let config = makeConfig()
        let start = date(hour: 11)
        engine.startAutoClock(at: start)
        engine.start(trigger: .manual, at: start, config: config, calendar: calendar)

        engine.setPaused(true, at: start.addingTimeInterval(30))
        XCTAssertFalse(engine.isBoosting)
        XCTAssertEqual(engine.tick(at: start.addingTimeInterval(31), config: config, calendar: calendar).intensity, 0)
    }

    func testPausedEngineRefusesToStart() {
        var engine = LightBoostEngine()
        let config = makeConfig()
        let now = date(hour: 11)
        engine.setPaused(true, at: now)
        XCTAssertFalse(engine.start(trigger: .manual, at: now, config: config, calendar: calendar))
    }

    /// Coming back to the desk must not fire a boost in your face; the wait
    /// starts again from the moment you return.
    func testResumingRestartsTheWaitRatherThanFiringImmediately() {
        var engine = LightBoostEngine()
        let config = makeConfig(autoInterval: 15 * 60)
        let start = date(hour: 9)
        engine.startAutoClock(at: start)
        engine.setPaused(true, at: start.addingTimeInterval(60))

        let back = start.addingTimeInterval(60 * 60)
        engine.setPaused(false, at: back)
        XCTAssertEqual(engine.autoClockStartedAt, back)
        XCTAssertFalse(engine.tick(at: back.addingTimeInterval(60), config: config, calendar: calendar).didStart)
        XCTAssertTrue(engine.tick(at: back.addingTimeInterval(15 * 60), config: config, calendar: calendar).didStart)
    }

    // MARK: - Config safety

    func testAutomaticBoostIsCancelledWhenItCrossesTheCutoff() {
        var engine = LightBoostEngine()
        let config = makeConfig(duration: 600, cutoffHour: 20)
        let start = date(hour: 19, minute: 57)
        engine.start(trigger: .automatic, at: start, config: config, calendar: calendar)

        let result = engine.tick(at: date(hour: 20, minute: 1), config: config, calendar: calendar)
        XCTAssertTrue(result.didEnd)
        XCTAssertEqual(result.intensity, 0)
    }

    /// Cutting a manual boost short mid-fade would overrule a choice the user
    /// made moments earlier.
    func testManualBoostSurvivesCrossingTheCutoff() {
        var engine = LightBoostEngine()
        let config = makeConfig(duration: 600, cutoffHour: 20)
        let start = date(hour: 19, minute: 57)
        engine.start(trigger: .manual, at: start, config: config, calendar: calendar)

        let result = engine.tick(at: date(hour: 20, minute: 1), config: config, calendar: calendar)
        XCTAssertFalse(result.didEnd)
        XCTAssertTrue(engine.isBoosting)
        XCTAssertEqual(result.intensity, config.peakIntensity, accuracy: 0.001)
    }

    func testRunningBoostEndsWhenFeatureIsDisabledMidSession() {
        var engine = LightBoostEngine()
        var config = makeConfig()
        let start = date(hour: 11)
        engine.start(trigger: .manual, at: start, config: config, calendar: calendar)

        config.isEnabled = false
        let result = engine.tick(at: start.addingTimeInterval(10), config: config, calendar: calendar)
        XCTAssertEqual(result.intensity, 0)
        XCTAssertFalse(engine.isBoosting)
    }

    func testClampingBoundsUserEditableValues() {
        let wild = LightBoostConfig(
            autoInterval: 1,
            duration: 99_999,
            peakIntensity: 5.0,
            cutoffHour: 99,
            startHour: -4
        ).clamped()

        XCTAssertEqual(wild.autoInterval, LightBoostConfig.autoIntervalRange.lowerBound)
        XCTAssertEqual(wild.duration, LightBoostConfig.durationRange.upperBound)
        XCTAssertEqual(wild.peakIntensity, LightBoostConfig.peakIntensityRange.upperBound)
        XCTAssertEqual(wild.cutoffHour, 23)
        XCTAssertEqual(wild.startHour, 0)
    }

    func testDefaultsMatchTheShippedBehaviour() {
        let config = LightBoostConfig.default
        XCTAssertEqual(config.autoInterval, 15 * 60)
        XCTAssertEqual(config.duration, 90)
        // Sharp exit, slow entry: the asymmetry is the point, not an accident.
        XCTAssertLessThan(config.rampDown, config.rampUp / 4)
        XCTAssertEqual(config.cutoffHour, 20)
        XCTAssertTrue(config.isAutoEnabled)
    }
}
