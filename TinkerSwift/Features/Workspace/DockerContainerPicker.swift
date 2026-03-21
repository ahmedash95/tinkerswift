import Foundation
import Observation
import SwiftUI

struct DockerContainerPicker: View {
    @Environment(WorkspaceState.self) private var workspaceState
    
    @Binding var selectedContainerID: String
    @Binding var selectedContainerName: String
    
    @State private var searchText = ""
    @State private var containers: [DockerContainerSummary] = []
    @State private var isLoadingContainers = false
    @State private var errorMessage = ""
    
    private var filteredContainers: [DockerContainerSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return containers }
        return containers.filter { container in
            container.name.localizedCaseInsensitiveContains(query) ||
                container.image.localizedCaseInsensitiveContains(query) ||
                container.id.localizedCaseInsensitiveContains(query)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchBar
            
            mainContent
            
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task {
            await loadContainers()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search containers...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            
            Button {
                Task { await loadContainers() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingContainers)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if isLoadingContainers {
            loadingView
        } else if filteredContainers.isEmpty {
            emptyView
        } else {
            containerList
        }
    }

    private var loadingView: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Text("Loading containers...").font(.caption)
            Spacer()
        }
        .frame(height: 170)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.largeTitle)
            Text("No running containers found").font(.headline)
            Text("Make sure Docker is running.").font(.caption)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 170)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var containerList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(filteredContainers) { container in
                    ContainerRowView(
                        container: container,
                        isSelected: selectedContainerID == container.id,
                        onSelect: {
                            selectedContainerID = container.id
                            selectedContainerName = container.name
                        }
                    )
                }
            }
        }
        .frame(minHeight: 170, maxHeight: 250)
    }
    
    private func loadContainers() async {
        isLoadingContainers = true
        errorMessage = ""
        containers = await workspaceState.listDockerContainers()
        isLoadingContainers = false
        
        if !selectedContainerID.isEmpty && !containers.contains(where: { $0.id == selectedContainerID }) {
            if let match = containers.first(where: { $0.name == selectedContainerName }) {
                selectedContainerID = match.id
            }
        }
    }
}

struct ContainerRowView: View {
    let container: DockerContainerSummary
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(isSelected ? .white : .accentColor)
                    .frame(width: 32, height: 32)
                    .background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.1))
                    .cornerRadius(6)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name)
                        .font(.body.weight(.medium))
                    
                    Text("\(container.image) • \(container.status)")
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white)
                }
            }
            .padding(10)
            .background(isSelected ? Color.accentColor : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}
