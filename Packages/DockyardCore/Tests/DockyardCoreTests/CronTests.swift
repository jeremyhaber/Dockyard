@testable import DockyardCore
import ConnectionKit
import Foundation
import Testing

@Suite struct CronScheduleTests {
    private func schedule(_ text: String) throws -> CronSchedule { try CronSchedule(text) }

    @Test func parsesListsRangesStepsAndNames() throws {
        let s = try schedule("0,30 9-17/2 * jan,mar mon-fri")
        #expect(s.minute.values == [0, 30])
        #expect(s.hour.values == [9, 11, 13, 15, 17])
        #expect(s.month.values == [1, 3])
        #expect(s.dayOfWeek.values == [1, 2, 3, 4, 5])
        #expect(try schedule("0 0 * * 7").dayOfWeek.values == [0])
        #expect(try schedule("*/15 * * * *").minute.values == [0, 15, 30, 45])
    }

    @Test func rejectsBadFieldsWithClearMessages() {
        #expect(CronSchedule.validate("* * * *")?.contains("five fields") == true)
        #expect(CronSchedule.validate("60 * * * *")?.contains("outside the minute range 0-59") == true)
        #expect(CronSchedule.validate("* 24 * * *")?.contains("hour") == true)
        #expect(CronSchedule.validate("* * 0 * *")?.contains("day of month") == true)
        #expect(CronSchedule.validate("* * * foo *")?.contains("not a valid month") == true)
        #expect(CronSchedule.validate("5-1 * * * *")?.contains("backwards") == true)
        #expect(CronSchedule.validate("*/0 * * * *")?.contains("step") == true)
        #expect(CronSchedule.validate("@sometimes")?.contains("shortcut") == true)
        #expect(CronSchedule.validate("*/5 * * * *") == nil)
        #expect(CronSchedule.validate("@reboot") == nil)
    }

    @Test func describesCommonSchedules() throws {
        #expect(try schedule("* * * * *").summary == "Every minute")
        #expect(try schedule("*/5 * * * *").summary == "Every 5 minutes")
        #expect(try schedule("0 * * * *").summary == "Every hour")
        #expect(try schedule("15 * * * *").summary == "Every hour at minute 15")
        #expect(try schedule("30 3 * * *").summary == "Daily at 03:30")
        #expect(try schedule("0 9 * * 1").summary == "Mondays at 09:00")
        #expect(try schedule("0 9 * * 1-5").summary == "Weekdays at 09:00")
        #expect(try schedule("0 9 * * mon,wed,fri").summary == "Mondays, Wednesdays and Fridays at 09:00")
        #expect(try schedule("0 */2 * * *").summary == "At minute 0 past every 2nd hour")
        #expect(try schedule("0 4 1 * *").summary == "Monthly on the 1st at 04:00")
        #expect(try schedule("0 6,18 * * *").summary == "Daily at 06:00 and 18:00")
        #expect(try schedule("@reboot").summary == "At reboot")
        #expect(try schedule("@daily").summary == "Daily at 00:00")
        #expect(try schedule("0 0 1 jan *").summary == "On the 1st in January at 00:00")
    }

    @Test func fallsBackToTheExpression() throws {
        let odd = try schedule("*/7 9-17 * * 1-5")
        #expect(odd.summary == "*/7 9-17 * * 1-5")
        #expect(odd.isDescribedRaw)
    }

    private var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, tz: TimeZone? = nil) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz ?? utc
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func nextRunsAreStrictlyAfterAndInOrder() throws {
        let runs = try schedule("*/20 * * * *").nextRuns(after: date(2026, 11, 10, 10, 20), count: 3, in: utc)
        #expect(runs == [date(2026, 11, 10, 10, 40), date(2026, 11, 10, 11, 0), date(2026, 11, 10, 11, 20)])
    }

    @Test func nextRunsHonourTimeZone() throws {
        let tokyo = TimeZone(secondsFromGMT: 9 * 3600)!
        // 2026-11-10 00:00 UTC is 09:00 in Tokyo, so the next 10:00 job is an hour later.
        let runs = try schedule("0 10 * * *").nextRuns(after: date(2026, 11, 10, 0, 0), count: 1, in: tokyo)
        #expect(runs == [date(2026, 11, 10, 1, 0)])
    }

    @Test func dayOfMonthAndWeekAreOred() throws {
        // 2026-11-01 is a Sunday. "the 15th or any Monday": Nov 2 (Mon), 9, 15, 16.
        let runs = try schedule("0 0 15 * 1").nextRuns(after: date(2026, 11, 1, 12, 0), count: 4, in: utc)
        #expect(runs == [date(2026, 11, 2, 0, 0), date(2026, 11, 9, 0, 0), date(2026, 11, 15, 0, 0), date(2026, 11, 16, 0, 0)])
        // With a wildcard day-of-week only day-of-month counts.
        let monthly = try schedule("0 0 15 * *").nextRuns(after: date(2026, 11, 1, 0, 0), count: 2, in: utc)
        #expect(monthly == [date(2026, 11, 15, 0, 0), date(2026, 12, 15, 0, 0)])
    }

    @Test func impossibleDatesAndRebootGiveNothing() throws {
        #expect(try schedule("0 0 31 2 *").nextRuns(after: date(2026, 1, 1, 0, 0), count: 2, in: utc).isEmpty)
        #expect(try schedule("@reboot").nextRuns(after: Date(), count: 2, in: utc).isEmpty)
    }

    @Test func leapDayIsFound() throws {
        let runs = try schedule("0 12 29 2 *").nextRuns(after: date(2026, 1, 1, 0, 0), count: 1, in: utc)
        #expect(runs == [date(2028, 2, 29, 12, 0)])
    }
}

@Suite struct CronPresetTests {
    private func preset(_ text: String) throws -> CronPreset { CronPreset.matching(try CronSchedule(text)) }

    @Test func mapsSchedulesToPresets() throws {
        #expect(try preset("* * * * *") == .everyMinute)
        #expect(try preset("*/10 * * * *") == .everyNMinutes(10))
        #expect(try preset("45 * * * *") == .hourly(minute: 45))
        #expect(try preset("30 3 * * *") == .daily(hour: 3, minute: 30))
        #expect(try preset("0 9 * * 1,3,5") == .weekly(days: [1, 3, 5], hour: 9, minute: 0))
        #expect(try preset("0 9 * * mon-fri") == .custom("0 9 * * mon-fri"))
        #expect(try preset("15 2 10 * *") == .monthly(day: 10, hour: 2, minute: 15))
        #expect(try preset("@reboot") == .reboot)
        #expect(try preset("@weekly") == .weekly(days: [0], hour: 0, minute: 0))
        #expect(try preset("*/7 9-17 * * 1-5") == .custom("*/7 9-17 * * 1-5"))
    }

    @Test func presetsProduceValidExpressionsThatMapBack() throws {
        let all: [CronPreset] = [
            .everyMinute, .everyNMinutes(5), .hourly(minute: 17), .daily(hour: 6, minute: 5),
            .weekly(days: [0, 6], hour: 8, minute: 0), .monthly(day: 28, hour: 23, minute: 59), .reboot,
        ]
        for p in all {
            let schedule = try CronSchedule(p.expression)
            #expect(CronPreset.matching(schedule) == p, "\(p.expression)")
        }
    }
}

@Suite struct CrontabTests {
    static let sample = """
    # Edit this file to introduce tasks to be run by cron.
    # m h  dom mon dow   command
    MAILTO=ops@example.com
    PATH=/usr/local/bin:/usr/bin:/bin
    CRON_TZ=Europe/Berlin

    # Nightly database backup
    30 2 * * * /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1
    #*/5 * * * * /opt/check.sh
    # Weekly report
    # 0 9 * * 1 /opt/report --send
    @reboot   /opt/start.sh
    this is not valid
    */5 * * * * echo "a % b"   
    """

    @Test func roundTripIsByteForByte() {
        for text in [Self.sample, Self.sample + "\n", "", "\n", "\n\n", "# only a comment", "\r\n* * * * * x\r\n",
                     "  * * * * *   spaced   out  \n\t\n#   \n"] {
            #expect(Crontab(parsing: text).serialized() == text, "\(text.debugDescription)")
        }
    }

    @Test func parsesJobsLabelsEnvAndDisabled() throws {
        let tab = Crontab(parsing: Self.sample)
        let jobs = tab.jobs
        #expect(jobs.count == 5)
        #expect(jobs[0].label == "Nightly database backup")
        #expect(jobs[0].command == "/usr/local/bin/backup.sh >> /var/log/backup.log 2>&1")
        #expect(jobs[0].enabled)
        #expect(jobs[1].enabled == false)
        #expect(jobs[1].schedule.expression == "*/5 * * * *")
        #expect(jobs[2].enabled == false && jobs[2].label == "Weekly report")
        #expect(jobs[3].schedule.isReboot && jobs[3].command == "/opt/start.sh")
        #expect(tab.envVars.map(\.name) == ["MAILTO", "PATH", "CRON_TZ"])
        #expect(tab.cronTimeZone == "Europe/Berlin")
        // The stock header line is not taken as a label.
        #expect(jobs.allSatisfy { $0.label != "m h  dom mon dow   command" })
    }

    @Test func keepsUnknownLinesAndReportsThem() {
        let tab = Crontab(parsing: Self.sample)
        #expect(tab.unknownLineCount == 1)
        #expect(tab.issues.map(\.line) == [13])
        let bad = Crontab(parsing: "99 * * * * run\n")
        #expect(bad.issues.first?.message.contains("minute") == true)
        #expect(bad.serialized() == "99 * * * * run\n")
    }

    @Test func editingRewritesOnlyTheChangedLines() throws {
        var tab = Crontab(parsing: Self.sample)
        var job = tab.jobs[0]
        job.schedule = try CronSchedule("0 3 * * *")
        tab.update(job)
        let out = tab.serialized()
        #expect(out.contains("# Nightly database backup\n0 3 * * * /usr/local/bin/backup.sh"))
        #expect(out.contains("#*/5 * * * * /opt/check.sh\n"))   // untouched disabled job keeps its odd spacing
        tab.setEnabled(false, id: tab.jobs[0].id)
        #expect(tab.serialized().contains("# 0 3 * * * /usr/local/bin/backup.sh"))
        tab.setEnabled(true, id: tab.jobs[1].id)
        #expect(tab.serialized().contains("\n*/5 * * * * /opt/check.sh\n"))
    }

    @Test func addDuplicateRemoveAndLabels() throws {
        var tab = Crontab(parsing: "MAILTO=a@b.c\n")
        tab.add(CronJob(label: "Ping", schedule: try CronSchedule("*/5 * * * *"), command: "curl -s example.com"))
        #expect(tab.serialized() == "MAILTO=a@b.c\n# Ping\n*/5 * * * * curl -s example.com\n")
        let firstID = tab.jobs[0].id
        let made = tab.duplicate(id: firstID)
        let copy = try #require(made)
        #expect(copy.label == "Ping (copy)")
        #expect(tab.jobs.count == 2)
        tab.remove(id: copy.id)
        var job = tab.jobs[0]
        job.label = ""
        tab.update(job)
        #expect(tab.serialized() == "MAILTO=a@b.c\n*/5 * * * * curl -s example.com\n")
        tab.addEnv(name: "SHELL", value: "/bin/bash")
        #expect(tab.serialized().hasPrefix("MAILTO=a@b.c\nSHELL=/bin/bash\n"))
    }

    @Test func addingToACrontabWithoutFinalNewlineEndsItProperly() throws {
        var tab = Crontab(parsing: "* * * * * a")
        tab.add(CronJob(schedule: try CronSchedule("@hourly"), command: "b"))
        #expect(tab.serialized() == "* * * * * a\n@hourly b\n")
    }

    @Test func commandValidation() throws {
        let s = try CronSchedule("* * * * *")
        #expect(CronJob(schedule: s, command: "  ").validationError != nil)
        #expect(CronJob(schedule: s, command: "a\nb").validationError != nil)
        #expect(CronJob(schedule: s, command: "a").validationError == nil)
    }
}

final class FakeCrontabRunner: RemoteCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _text: String?
    private var _commands: [String] = []
    private var _stdins: [String] = []
    var rejectInstall: String?
    var onRead: (@Sendable () -> Void)?

    init(text: String?) { _text = text }
    var text: String? { lock.withLock { _text } }
    func setText(_ value: String?) { lock.withLock { _text = value } }
    var commands: [String] { lock.withLock { _commands } }
    var stdins: [String] { lock.withLock { _stdins } }

    func exec(_ command: String) async throws -> SSHExecResult { SSHExecResult(exitStatus: 127) }

    func execStream(_ command: String, elevated: Bool, stdin: Data?) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        lock.withLock { _commands.append(command) }
        var events: [SSHExecEvent] = []
        switch command {
        case "crontab -l":
            onRead?()
            if let text = text { events = [.stdout(Data(text.utf8)), .exit(0)] } else {
                events = [.stderr(Data("no crontab for deploy\n".utf8)), .exit(1)]
            }
        case "crontab -":
            let body = String(decoding: stdin ?? Data(), as: UTF8.self)
            lock.withLock { _stdins.append(body) }
            if let rejectInstall {
                events = [.stderr(Data(rejectInstall.utf8)), .exit(1)]
            } else {
                setText(body)
                events = [.exit(0)]
            }
        case let c where c.hasPrefix("date"):
            events = [.stdout(Data("2026-11-10 14:03:22 +0100 CET\n".utf8)), .exit(0)]
        default:
            events = [.exit(127)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func execStream(_ command: String, elevated: Bool) async throws -> AsyncThrowingStream<SSHExecEvent, Error> {
        try await execStream(command, elevated: elevated, stdin: nil)
    }
}

@Suite struct CronRemoteTests {
    @Test func loadsAndTreatsNoCrontabAsEmpty() async throws {
        let existing = FakeCrontabRunner(text: "* * * * * x\n")
        #expect(try await CronRemote(runner: existing).load() == "* * * * * x\n")
        let none = FakeCrontabRunner(text: nil)
        #expect(try await CronRemote(runner: none).load() == "")
    }

    @Test func parsesServerClock() async throws {
        let clock = try #require(await CronRemote(runner: FakeCrontabRunner(text: "")).serverClock())
        #expect(clock.timeZone.secondsFromGMT() == 3600)
        #expect(clock.abbreviation == "CET")
        var c = Calendar(identifier: .gregorian)
        c.timeZone = clock.timeZone
        #expect(c.component(.hour, from: clock.date) == 14)
        #expect(CronServerClock.parse("garbage") == nil)
    }

    @Test func savesThroughStdinAndLogsOnlyACount() async throws {
        let runner = FakeCrontabRunner(text: "old\n")
        let logged = LockedBox<[String]>([])
        let remote = CronRemote(runner: runner) { _, m in logged.withLock { $0.append(m) } }
        try await remote.save("MAILTO=secret@example.com\n* * * * * PASSWORD=hunter2 run", expecting: "old\n")
        #expect(runner.text == "MAILTO=secret@example.com\n* * * * * PASSWORD=hunter2 run\n")
        #expect(logged.withLock { $0 } == ["Saved crontab (1 jobs)"])
        #expect(!runner.commands.contains { $0.contains("hunter2") })
    }

    @Test func detectsAConcurrentChange() async throws {
        let runner = FakeCrontabRunner(text: "theirs\n")
        let remote = CronRemote(runner: runner)
        do {
            try await remote.save("mine\n", expecting: "original\n")
            Issue.record("expected a conflict")
        } catch let error as CronRemoteError {
            #expect(error == .changedOnServer(current: "theirs\n"))
        }
        #expect(runner.text == "theirs\n")
        try await remote.save("mine\n", expecting: nil)
        #expect(runner.text == "mine\n")
    }

    @Test func surfacesCrontabsComplaint() async throws {
        let runner = FakeCrontabRunner(text: "")
        runner.rejectInstall = "\"-\":3: bad minute\nerrors in crontab file, can't install.\n"
        let logged = LockedBox<[String]>([])
        let remote = CronRemote(runner: runner) { _, m in logged.withLock { $0.append(m) } }
        do {
            try await remote.save("99 * * * * x\n", expecting: "")
            Issue.record("expected a rejection")
        } catch let error as CronRemoteError {
            #expect(error.description.contains("bad minute"))
        }
        #expect(!logged.withLock { $0 }.joined().contains("99"))
    }
}
