import ConnectionKit
import DockyardCore
import SwiftUI

/// View and edit a server's crontab without `crontab -e`.
struct CronSheet: View {
    @Environment(AppModel.self) private var app
    @State private var model: CronEditorModel
    @State private var selection: Set<Int> = []
    @State private var editing: JobEditRequest?
    @State private var confirmCancel = false
    @State private var confirmDelete = false
    @State private var textModeNotice: String?

    init(session: ConnectionSession, runner: any RemoteCommandRunner) {
        _model = State(initialValue: CronEditorModel(session: session, runner: runner))
    }

    private var session: ConnectionSession { model.session }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let error = model.saveError {
                Divider()
                Label(error, systemImage: "xmark.octagon")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 600)
        .task { await model.start() }
        .interactiveDismissDisabled(model.isDirty)
        .sheet(item: $editing) { request in
            CronJobEditor(request: request, timeZone: model.timeZone, now: model.serverNow, zoneLabel: model.timeZoneLabel) { job in
                if request.job.id == 0 { model.crontab.add(job) } else { model.crontab.update(job) }
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { close() }
        } message: { Text("Your edits to the crontab on \(session.connection.name) have not been saved.") }
        .confirmationDialog("Delete \(selectedJobs.count) job\(selectedJobs.count == 1 ? "" : "s")?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: { Text("They are removed from the crontab when you save.") }
        .confirmationDialog("The crontab changed on the server", isPresented: conflictBinding, titleVisibility: .visible) {
            Button("Reload and Discard My Edits", role: .destructive) { Task { await model.reloadAfterConflict() } }
            Button("Overwrite with My Version", role: .destructive) { model.conflict = nil; Task { await model.save(overwrite: true) } }
            Button("Cancel", role: .cancel) { model.conflict = nil }
        } message: {
            Text("Someone or something edited it after you opened it. Reload to see their version, or overwrite it with yours.")
        }
        .alert("Cannot switch back yet", isPresented: Binding(get: { textModeNotice != nil }, set: { if !$0 { textModeNotice = nil } })) {
            Button("OK") { textModeNotice = nil }
        } message: { Text(textModeNotice ?? "") }
    }

    private var conflictBinding: Binding<Bool> {
        Binding(get: { model.conflict != nil }, set: { if !$0 { model.conflict = nil } })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cron Jobs \u{2014} \(session.connection.name)").font(.headline)
                Text(model.phase == .ready ? model.timeZoneLabel : "Reading the crontab\u{2026}")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if model.phase == .loading || model.saving { ProgressView().controlSize(.small) }
            if model.canElevate {
                Toggle("Root\u{2019}s crontab", isOn: Binding(get: { model.elevated }, set: { on in Task { await model.switchRoot(on) } }))
                    .toggleStyle(.checkbox)
                    .disabled(model.isDirty || model.saving)
                    .help(model.isDirty ? "Save or revert your changes first" : "Edit root\u{2019}s crontab instead of your own, using this connection\u{2019}s su or sudo")
            }
            Picker("View", selection: modeBinding) {
                Text("Jobs").tag(CronEditorModel.Mode.jobs)
                Text("Text").tag(CronEditorModel.Mode.text)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
        }
        .padding(12)
    }

    private var modeBinding: Binding<CronEditorModel.Mode> {
        Binding<CronEditorModel.Mode>(get: { model.mode }, set: { switchMode($0) })
    }

    private func switchMode(_ new: CronEditorModel.Mode) {
        guard model.phase == .ready else { return }
        if !model.setMode(new) {
            textModeNotice = "Some lines are not valid cron entries. Fix them in the text first (they are listed under the editor), or save the text as it is and let the server judge."
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let text):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(Palette.textSecondary)
                Text(text).multilineTextAlignment(.center).foregroundStyle(Palette.textSecondary).frame(maxWidth: 460)
                    .textSelection(.enabled)
                Button("Try Again") { Task { await model.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if model.mode == .text { textEditor } else { jobsView }
        }
    }

    private var jobsView: some View {
        VStack(spacing: 0) {
            if model.crontab.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus").font(.system(size: 28)).foregroundStyle(Palette.textSecondary)
                    Text("No scheduled jobs yet.\nChoose Add to schedule a command.")
                        .multilineTextAlignment(.center).foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                jobTable
            }
            Divider()
            CronEnvSection(model: model)
            if model.crontab.unknownLineCount > 0 {
                Divider()
                Label("\(model.crontab.unknownLineCount) line\(model.crontab.unknownLineCount == 1 ? " is" : "s are") not valid cron entries and kept as written. Switch to Text to see them.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Palette.statusAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private var selectedJobs: [CronJob] { model.crontab.jobs.filter { selection.contains($0.id) } }

    private var jobTable: some View {
        Table(model.crontab.jobs, selection: $selection) {
            TableColumn("") { job in
                Toggle("Enabled", isOn: Binding(get: { job.enabled }, set: { model.crontab.setEnabled($0, id: job.id) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(job.enabled ? "Comment this job out" : "Turn this job back on")
            }
            .width(24)
            TableColumn("Job") { job in
                Text(job.label.isEmpty ? "Untitled" : job.label)
                    .foregroundStyle(job.label.isEmpty ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                    .opacity(job.enabled ? 1 : 0.5)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 160)
            TableColumn("Schedule") { job in
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.schedule.summary).lineLimit(1)
                    Text(job.schedule.expression).font(.monoSmall).foregroundStyle(.secondary).lineLimit(1)
                }
                .opacity(job.enabled ? 1 : 0.5)
            }
            .width(min: 150, ideal: 200)
            TableColumn("Command") { job in
                Text(job.command).font(.mono).lineLimit(1).truncationMode(.tail)
                    .opacity(job.enabled ? 1 : 0.5)
                    .help(job.command)
            }
            TableColumn("Next run") { job in
                Text(nextRunText(job))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            Button("Edit\u{2026}") { edit(ids.first) }
            Button("Duplicate") { ids.forEach { duplicate($0) } }
            Button("Delete\u{2026}") { selection = ids; confirmDelete = true }
        } primaryAction: { ids in
            edit(ids.first)
        }
        .accessibilityLabel("Cron jobs")
    }

    private func nextRunText(_ job: CronJob) -> String {
        guard job.enabled else { return "Off" }
        if job.schedule.isReboot { return "At reboot" }
        guard let next = job.schedule.nextRuns(after: model.serverNow, count: 1, in: model.timeZone).first else { return "Never" }
        return CronFormat.runTime(next, in: model.timeZone, relativeTo: model.serverNow)
    }

    private var textEditor: some View {
        VStack(spacing: 0) {
            TextEditor(text: Binding(get: { model.rawText }, set: { model.rawText = $0 }))
                .font(.mono)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .background(Palette.ground)
                .padding(4)
                .accessibilityLabel("Crontab text")
            Divider()
            let issues = model.textIssues
            if issues.isEmpty {
                Label("Every line is valid. Switch to Jobs to edit visually.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(Palette.statusGreen)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(issues) { issue in
                            Text("Line \(issue.line): \(issue.message)").font(.caption).foregroundStyle(Palette.statusAmber)
                        }
                        Text("You cannot switch back to Jobs until these are fixed. Saving still works: the text is installed as written and the server checks it.")
                            .font(.caption).foregroundStyle(Palette.textSecondary).padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 90)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.mode == .jobs, model.phase == .ready {
                Button("Add\u{2026}") { editing = JobEditRequest(job: nil) }
                Button("Edit\u{2026}") { edit(selection.first) }.disabled(selection.count != 1)
                Button("Duplicate") { selection.forEach { duplicate($0) } }.disabled(selection.isEmpty)
                Button("Delete\u{2026}") { confirmDelete = true }.disabled(selection.isEmpty)
            }
            Spacer()
            Text(footerStatus).font(.caption).foregroundStyle(model.isDirty ? Palette.statusAmber : Palette.textSecondary)
            Button(model.revertTitle) { model.revert() }
                .disabled(!model.canRevert || model.saving)
                .help(model.isDirty ? "Throw away your edits" : "Put back the crontab from when this sheet opened")
            Button(model.isDirty ? "Cancel" : "Close") { model.isDirty ? (confirmCancel = true) : close() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isDirty || model.saving || model.validationError != nil)
                .help(model.validationError ?? "Install this crontab on the server")
        }
        .padding(12)
    }

    private var footerStatus: String {
        guard model.phase == .ready else { return "" }
        let count = "\(model.jobCount) job\(model.jobCount == 1 ? "" : "s")"
        if let problem = model.validationError { return problem }
        return model.isDirty ? "Unsaved changes \u{00B7} \(count)" : count
    }

    // MARK: Actions

    private func close() { app.safety.cronSessionID = nil }

    private func edit(_ id: Int?) {
        guard let id, let job = model.crontab.job(id: id) else { return }
        editing = JobEditRequest(job: job)
    }

    private func duplicate(_ id: Int) {
        if let copy = model.crontab.duplicate(id: id) { selection = [copy.id] }
    }

    private func deleteSelected() {
        for job in selectedJobs { model.crontab.remove(id: job.id) }
        selection = []
    }
}

/// A job to edit, or a new one when `job` is nil.
struct JobEditRequest: Identifiable {
    let id = UUID()
    let job: CronJob

    init(job: CronJob?) {
        // Id 0 marks a job not yet in the crontab.
        self.job = job ?? CronJob(schedule: try! CronSchedule("0 3 * * *"), command: "")
    }
}

enum CronFormat {
    /// "Today 14:30", "Tomorrow 03:00" or "Mon Nov 16, 09:00", in the given zone.
    static func runTime(_ date: Date, in zone: TimeZone, relativeTo now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let clock = date.formatted(Date.FormatStyle(timeZone: zone).hour(.twoDigits(amPM: .omitted)).minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(clock)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(clock)"
        }
        let day = date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day())
        return "\(day), \(clock)"
    }
}

/// Environment variables (MAILTO, PATH, ...) in a small collapsible section.
private struct CronEnvSection: View {
    @Bindable var model: CronEditorModel
    @State private var expanded = false

    private static let common = ["MAILTO", "SHELL", "PATH", "CRON_TZ"]

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 4) {
                ForEach(model.crontab.envVars) { env in
                    HStack(spacing: 6) {
                        TextField("Name", text: Binding(get: { env.name }, set: { model.crontab.updateEnv(id: env.id, name: $0, value: env.value) }))
                            .frame(width: 140)
                            .foregroundStyle(CronEnvVar.isValidName(env.name) ? Palette.textPrimary : Color.red)
                        Text("=").foregroundStyle(Palette.textSecondary)
                        TextField("Value", text: Binding(get: { env.value }, set: { model.crontab.updateEnv(id: env.id, name: env.name, value: $0) }))
                        Button { model.crontab.remove(id: env.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(env.name)")
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.monoSmall)
                }
                HStack {
                    Menu("Add Variable") {
                        ForEach(Self.common.filter { name in !model.crontab.envVars.contains { $0.name == name } }, id: \.self) { name in
                            Button(name) { model.crontab.addEnv(name: name, value: "") }
                        }
                        Divider()
                        Button("Other\u{2026}") { model.crontab.addEnv(name: "NAME", value: "") }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Environment variables (\(model.crontab.envVars.count))").font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
