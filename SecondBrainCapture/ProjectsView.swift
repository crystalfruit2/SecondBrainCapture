import SwiftUI

/// The mobile twin of the project registry: every active project, its status,
/// and how much is still open on it. Read-only by design — projects change
/// through real work in a session, not through a phone tap. Content-only:
/// `FeaturesView` owns the shell shared across Market/Health/Projects.
struct ProjectsContent: View {
    @EnvironmentObject var store: DashboardStore

    private var projects: [ProjectSummary] { store.dashboard?.projects ?? [] }

    var body: some View {
        List {
            if projects.isEmpty {
                Section {
                    DashboardPlaceholder(icon: "square.stack.3d.up",
                                         title: "No projects",
                                         message: "Pull down to fetch the project registry.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(projects) { project in
                        ProjectRow(project: project)
                            .listRowInsets(EdgeInsets())
                    }
                } header: {
                    SectionHeader(title: "Active", count: projects.count).textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }
}

struct ProjectRow: View {
    let project: ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if project.openTasks > 0 {
                    TaskPill(text: "\(project.openTasks) open", style: .project)
                }
            }

            if !project.status.isEmpty {
                Text(project.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let next = project.nextAction, !next.isEmpty {
                Label(next, systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

#Preview {
    NavigationStack { ProjectsContent() }
        .environmentObject(DashboardStore())
        .environmentObject(AppConfig())
}
