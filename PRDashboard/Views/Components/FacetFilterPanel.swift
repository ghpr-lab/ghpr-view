import SwiftUI

struct FacetFilterPanel: View {
    @ObservedObject var viewModel: PRListViewModel
    let onSave: () -> Void
    @State private var selectedField: FacetFieldID = .githubLabel

    private let fields = FacetFieldID.allCases
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selectedField.providerTitle).font(.headline)
                Spacer()
                Button("Clear") { viewModel.clearFacetField(selectedField) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .frame(height: 28)
                    .disabled((viewModel.activeFacetSelections[selectedField] ?? []).isEmpty)
                Button("Save View", action: onSave)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .frame(height: 28)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(fields, id: \.self) { field in
                        Button { selectedField = field } label: {
                            HStack { Image(systemName: field.symbolName).frame(width: 14); Text(field.title); Spacer(); if !(viewModel.activeFacetSelections[field] ?? []).isEmpty { Text("\(viewModel.activeFacetSelections[field]!.count)").font(.caption2) } }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedField == field ? Color.accentColor.opacity(0.15) : Color.clear)
                                .cornerRadius(5)
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }.frame(width: 125).padding(6)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.facetOptions(for: selectedField)) { option in
                            Button { viewModel.toggleFacet(field: selectedField, key: option.key) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: (viewModel.activeFacetSelections[selectedField] ?? []).contains(option.key) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(.accentColor)
                                    Image(systemName: selectedField.symbolName).foregroundColor(.secondary)
                                    Text(option.displayName).lineLimit(1)
                                    Spacer()
                                    Text("\(option.count)").foregroundColor(.secondary).font(.caption)
                                }
                                .padding(.horizontal, 7).padding(.vertical, 5)
                                .background((viewModel.activeFacetSelections[selectedField] ?? []).contains(option.key) ? Color.accentColor.opacity(0.12) : Color.clear)
                                .cornerRadius(4)
                            }.buttonStyle(.plain)
                        }
                        if viewModel.facetOptions(for: selectedField).isEmpty { Text("No matching options").foregroundColor(.secondary).padding(12) }
                    }.padding(6)
                }
            }
        }
        .frame(height: 210)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
