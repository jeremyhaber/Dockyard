import DockyardCore
import SwiftUI

/// Add or edit one cron job: a friendly schedule picker, or five raw fields, with a live preview.
struct CronJobEditor: View {
    @Environment(\.dismiss) private var dismiss
    let request: JobEditRequest
    let timeZone: TimeZone
    let now: Date
    let zoneLabel: String
    let onSave: (CronJob) -> Void

    @State private var label: String
    @State private var command: String
    @State private var enabled: Bool
    @State private var kind: CronPreset.Kind
    @State private var everyN = 5
    @State private var minute = 0
    @State private var hour = 3
    @State private var days: Set<Int> = [1]
    @State private var dayOfMonth = 1
    @State private var fields: [String]

    init(request: JobEditRequest, timeZone: TimeZone, now: Date, zoneLabel: String, onSave: @escaping (CronJob) -> Void) {
        self.request = request
        self.timeZone = timeZone
        self.now = now
        self.zoneLabel = zoneLabel
        self.onSave = onSave
        let job = request.job
        let preset = CronPreset.matching(job.schedule)
        _label = State(initialValue: job.label)
        _command = State(initialValue: job.command)
        _enabled = State(initialValue: job.enabled)
        _kind = State(initialValue: preset.kind)
        _fields = State(initialValue: job.schedule.rawFields)
        switch preset {
        case .everyNMinutes(let n): _everyN = State(initialValue: n)
        case .hourly(let m): _minute = State(initialValue: m)
        case .daily(let h, let m): _hour = State(initialValue: h); _minute = State(initialValue: m)
        case .weekly(let d, let h, let m): _days = State(initialValue: d); _hour = State(initialValue: h); _minute = State(initialValue: m)
        case .monthly(let d, let h, let m): _dayOfMonth = State(initialValue: d); _hour = State(initialValue: h); _minute = State(initialValue: m)
        default: break
        }
    }

    private var isNew: Bool { request.job.id == 0 }

    /// The expression the current controls stand for.
    private var expression: String {
        switch kind {
        case .everyMinute: CronPreset.everyMinute.expression
        case .everyNMinutes: CronPreset.everyNMinutes(everyN).expression
        case .hourly: CronPreset.hourly(minute: minute).expression
        case .daily: CronPreset.daily(hour: hour, minute: minute).expression
        case .weekly: CronPreset.weekly(days: days, hour: hour, minute: minute).expression
        case .monthly: CronPreset.monthly(day: dayOfMonth, hour: hour, minute: minute).expression
        case .reboot: CronPreset.reboot.expression
        case .custom: CronSchedule.expression(minute: fields[0], hour: fields[1], dayOfMonth: fields[2], month: fields[3], dayOfWeek: fields[4])
        }
    }

    private var scheduleError: String? { CronSchedule.validate(expression) }
    private var schedule: CronSchedule? { try? CronSchedule(expression) }
    private var commandError: String? {
        CronJob(schedule: schedule ?? request.job.schedule, command: command).validationError
    }
    private var canSave: Bool { scheduleError == nil && commandError == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Cron Job" : "Edit Cron Job").font(.headline)
            Form {
                TextField("Label", text: $label, prompt: Text("Optional, shown above the job"))
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Command", text: $command, prompt: Text("/usr/local/bin/backup.sh"), axis: .vertical)
                        .font(.mono)
                        .lineLimit(1...4)
                    if let commandError, !command.isEmpty { Text(commandError).font(.caption).foregroundStyle(.red) }
                }
                Picker("Runs", selection: kindBinding) {
                    ForEach(CronPreset.Kind.allCases, id: \.self) { item in Text(item.title).tag(item) }
                }
                scheduleControls
                Toggle("Enabled", isOn: $enabled)
            }
            .formStyle(.columns)
            preview
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Done") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var kindBinding: Binding<CronPreset.Kind> {
        Binding<CronPreset.Kind>(get: { kind }, set: { switchKind($0) })
    }

    // MARK: Controls

    @ViewBuilder
    private var scheduleControls: some View {
        switch kind {
        case .everyMinute: EmptyView()
        case .everyNMinutes:
            LabeledContent("Every") {
                HStack {
                    Stepper(value: $everyN, in: 2...59) { Text("\(everyN) minutes").monospacedDigit() }
                }
            }
        case .hourly:
            LabeledContent("At minute") { numberPicker($minute, range: 0..<60, label: "Minute") }
        case .daily:
            LabeledContent("At") { timePicker }
        case .weekly:
            LabeledContent("On") { weekdayButtons }
            LabeledContent("At") { timePicker }
        case .monthly:
            LabeledContent("On day") { numberPicker($dayOfMonth, range: 1..<32, label: "Day of month", pad: false) }
            LabeledContent("At") { timePicker }
        case .reboot:
            Text("Runs once each time the server starts.").font(.caption).foregroundStyle(Palette.textSecondary)
        case .custom:
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(["Minute", "Hour", "Day", "Month", "Weekday"].enumerated()), id: \.offset) { index, title in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.caption).foregroundStyle(Palette.textSecondary)
                        TextField(title, text: $fields[index])
                            .font(.mono)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                }
            }
            if let scheduleError {
                Label(scheduleError, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func numberPicker(_ value: Binding<Int>, range: Range<Int>, label: String, pad: Bool = true) -> some View {
        Picker(label, selection: value) {
            ForEach(range, id: \.self) { Text(pad ? String(format: "%02d", $0) : "\($0)").tag($0) }
        }
        .labelsHidden()
        .frame(width: 70)
    }

    private var timePicker: some View {
        HStack(spacing: 4) {
            numberPicker($hour, range: 0..<24, label: "Hour")
            Text(":")
            numberPicker($minute, range: 0..<60, label: "Minute")
        }
    }

    private var weekdayButtons: some View {
        HStack(spacing: 4) {
            ForEach(Array(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].enumerated()), id: \.offset) { index, name in
                Toggle(name, isOn: Binding(
                    get: { days.contains(index) },
                    set: { on in
                        if on { days.insert(index) } else if days.count > 1 { days.remove(index) }
                    }))
                .toggleStyle(.button)
                .controlSize(.small)
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let schedule {
                Text(schedule.summary).font(.system(size: 13, weight: .medium))
                Text(schedule.expression).font(.monoSmall).foregroundStyle(Palette.textSecondary)
                Divider()
                Text("Next runs").font(.caption).foregroundStyle(Palette.textSecondary)
                let runs = schedule.nextRuns(after: now, count: 5, in: timeZone)
                if schedule.isReboot {
                    Text("At the next server reboot").font(.system(size: 12))
                } else if runs.isEmpty {
                    Text("This schedule never runs (for example, a day that does not exist in that month).")
                        .font(.caption).foregroundStyle(Palette.statusAmber)
                } else {
                    ForEach(runs, id: \.self) { run in
                        Text(CronFormat.runTime(run, in: timeZone, relativeTo: now)).font(.system(size: 12)).monospacedDigit()
                    }
                }
                Text(zoneLabel).font(.caption).foregroundStyle(Palette.textSecondary)
            } else if kind != .custom, let scheduleError {
                Text(scheduleError).font(.caption).foregroundStyle(.red)
            } else {
                Text("Fix the schedule above to see when it runs.").font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Actions

    /// Carries the current values across when the picker changes, so a time set for Daily survives a switch to Weekly.
    private func switchKind(_ new: CronPreset.Kind) {
        let current = CronPreset.matching((try? CronSchedule(expression)) ?? request.job.schedule)
        let next = CronPreset.defaults(for: new, from: current)
        kind = new
        switch next {
        case .everyNMinutes(let n): everyN = n
        case .hourly(let m): minute = m
        case .daily(let h, let m): hour = h; minute = m
        case .weekly(let d, let h, let m): days = d; hour = h; minute = m
        case .monthly(let d, let h, let m): dayOfMonth = d; hour = h; minute = m
        case .custom: fields = (try? CronSchedule(current.expression))?.rawFields ?? fields
        default: break
        }
    }

    private func commit() {
        guard let schedule, canSave else { return }
        var job = request.job
        job.label = label.trimmingCharacters(in: .whitespaces)
        job.command = command.trimmingCharacters(in: .whitespaces)
        job.schedule = schedule
        job.enabled = enabled
        onSave(job)
        dismiss()
    }
}
