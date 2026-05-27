import SwiftUI

struct ActivityView: View {
    @Environment(AppStore.self) private var store

    var onSelectGroup: (UUID) -> Void

    @State private var selectedGroupID: UUID? = nil

    var body: some View {
        let rows = filteredRows()
        let buckets = groupByDay(rows)
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        filterBar
                        ForEach(buckets) { bucket in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Self.dayLabel(for: bucket.date))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .tracking(0.6)
                                VStack(spacing: 8) {
                                    ForEach(bucket.rows) { row in
                                        Button {
                                            // Silent no-op when the source group was deleted.
                                            if store.group(id: row.groupID) != nil {
                                                onSelectGroup(row.groupID)
                                            }
                                        } label: {
                                            ActivityRowView(row: row, showsGroupBadge: selectedGroupID == nil)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        caveatFooter
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, BottomTabBar.height + 24)
                }
                .refreshable {
                    await store.foregroundRefresh(force: true)
                    await store.retryPendingRates()
                }
            }
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.large)
    }

    private struct ActivityDayBucket: Identifiable {
        var id: Date { date }
        let date: Date
        let rows: [ActivityRow]
    }

    private func groupByDay(_ rows: [ActivityRow]) -> [ActivityDayBucket] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: rows) { cal.startOfDay(for: $0.date) }
        return grouped
            .map { day, items in
                ActivityDayBucket(date: day, rows: items.sorted(by: { $0.date > $1.date }))
            }
            .sorted(by: { $0.date > $1.date })
    }

    private static let dayHeaderFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        df.doesRelativeDateFormatting = true
        return df
    }()

    private static func dayLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return dayHeaderFormatter.string(from: date)
    }

    private var emptyState: some View {
        CompactEmptyState(
            icon: "clock.arrow.circlepath",
            title: "No activity yet",
            description: "Actions across your groups will appear here."
        )
    }

    private var filterBar: some View {
        HStack {
            Menu {
                filterMenuContent
            } label: {
                HStack(spacing: 4) {
                    Text(filterLabel)
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
                .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("activityGroupFilter")
            Spacer()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var filterMenuContent: some View {
        Button("All groups") { selectedGroupID = nil }
        Divider()
        let active = store.groups.filter { $0.archivedAt == nil }
        ForEach(active) { group in
            Button {
                selectedGroupID = group.id
            } label: {
                Text("\(group.emoji ?? "👥") \(group.name)")
            }
        }
        let archived = store.groups.filter { $0.archivedAt != nil }
        if !archived.isEmpty {
            Divider()
            ForEach(archived) { group in
                Button {
                    selectedGroupID = group.id
                } label: {
                    Text("\(group.emoji ?? "👥") \(group.name) (archived)")
                }
            }
        }
    }

    private var filterLabel: String {
        if let id = selectedGroupID, let group = store.group(id: id) {
            return "\(group.emoji ?? "👥") \(group.name)"
        }
        return "All groups"
    }

    private var caveatFooter: some View {
        Text("Creations and joins are reconstructed from current state; edits and deletions are logged.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 8)
    }

    private func filteredRows() -> [ActivityRow] {
        var rows: [ActivityRow] = []

        for event in ActivityBuilder.events(from: store.groups) {
            switch event.kind {
            case .groupCreated:
                rows.append(ActivityRow(
                    id: event.id, date: event.date,
                    groupID: event.groupID, groupName: event.groupName,
                    kind: .groupCreated
                ))
            case .memberJoined(let name):
                rows.append(ActivityRow(
                    id: event.id, date: event.date,
                    groupID: event.groupID, groupName: event.groupName,
                    kind: .memberJoined(name: name)
                ))
            case .expenseAdded(let desc, let amount, let code, let payer):
                rows.append(ActivityRow(
                    id: event.id, date: event.date,
                    groupID: event.groupID, groupName: event.groupName,
                    kind: .expenseAdded(description: desc, amount: amount, currencyCode: code, payerName: payer)
                ))
            case .paymentRecorded(let from, let to, let amount, let code):
                rows.append(ActivityRow(
                    id: event.id, date: event.date,
                    groupID: event.groupID, groupName: event.groupName,
                    kind: .paymentRecorded(fromMemberName: from, toMemberName: to, amount: amount, currencyCode: code)
                ))
            }
        }

        for entry in store.activityLog {
            let groupName = store.group(id: entry.groupID)?.name ?? "Deleted group"
            switch entry.kind {
            case .expenseEdited(_, let desc, let changes):
                rows.append(ActivityRow(
                    id: entry.id, date: entry.date,
                    groupID: entry.groupID, groupName: groupName,
                    kind: .expenseEdited(description: desc, changes: changes),
                    editorName: entry.editorName
                ))
            case .expenseDeleted(_, let desc, let amount, let code, let payer):
                rows.append(ActivityRow(
                    id: entry.id, date: entry.date,
                    groupID: entry.groupID, groupName: groupName,
                    kind: .expenseDeleted(description: desc, amount: amount, currencyCode: code, payerName: payer)
                ))
            case .paymentRecorded(_, let from, let to, let amount, let code):
                rows.append(ActivityRow(
                    id: entry.id, date: entry.date,
                    groupID: entry.groupID, groupName: groupName,
                    kind: .paymentRecorded(fromMemberName: from, toMemberName: to, amount: amount, currencyCode: code)
                ))
            case .paymentEdited(_, let from, let to, let changes):
                rows.append(ActivityRow(
                    id: entry.id, date: entry.date,
                    groupID: entry.groupID, groupName: groupName,
                    kind: .paymentEdited(fromMemberName: from, toMemberName: to, changes: changes),
                    editorName: entry.editorName
                ))
            case .paymentDeleted(_, let from, let to, let amount, let code):
                rows.append(ActivityRow(
                    id: entry.id, date: entry.date,
                    groupID: entry.groupID, groupName: groupName,
                    kind: .paymentDeleted(fromMemberName: from, toMemberName: to, amount: amount, currencyCode: code)
                ))
            case .draftRecorded(let key):
                let (name, label) = resolveDraftEntity(key: key)
                rows.append(ActivityRow(
                    id: entry.id, date: entry.date,
                    groupID: entry.groupID, groupName: groupName,
                    kind: .draftRecorded(entityName: name, entityKindLabel: label)
                ))
            }
        }

        if let gid = selectedGroupID {
            rows.removeAll { $0.groupID != gid }
        }

        return rows.sorted { $0.date > $1.date }
    }

    private func resolveDraftEntity(key: EntityKey) -> (name: String?, label: String) {
        let group = store.group(id: key.groupID)
        switch key.kind {
        case .group:
            return (group?.name, "group")
        case .expense:
            let name = group?.expenses.first(where: { $0.id == key.id })?.description
            return (name, "expense")
        case .payment:
            return (nil, "payment")
        case .member:
            let name = group?.members.first(where: { $0.id == key.id })?.name
            return (name, "member")
        case .receipt:
            return (nil, "receipt")
        }
    }
}

private extension ActivityRow {
    func matches(query: String) -> Bool {
        if groupName.lowercased().contains(query) { return true }
        switch kind {
        case .groupCreated:
            return false
        case .memberJoined(let name):
            return name.lowercased().contains(query)
        case .expenseAdded(let desc, _, _, let payer),
             .expenseDeleted(let desc, _, _, let payer):
            return desc.lowercased().contains(query)
                || payer.lowercased().contains(query)
        case .expenseEdited(let desc, let changes):
            if desc.lowercased().contains(query) { return true }
            return changes.contains { $0.lowercased().contains(query) }
        case .paymentRecorded(let from, let to, _, _),
             .paymentDeleted(let from, let to, _, _):
            return from.lowercased().contains(query)
                || to.lowercased().contains(query)
        case .paymentEdited(let from, let to, let changes):
            if from.lowercased().contains(query) || to.lowercased().contains(query) { return true }
            return changes.contains { $0.lowercased().contains(query) }
        case .draftRecorded(let name, let label):
            if let name, name.lowercased().contains(query) { return true }
            return label.lowercased().contains(query)
        }
    }
}
