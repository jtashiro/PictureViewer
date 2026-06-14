//
//  GallerySelectionModel.swift
//  PictureViewer
//

import Combine
import Foundation

@MainActor
final class GallerySelectionModel: ObservableObject {
    @Published var selectedItems: Set<URL> = []
    @Published var isAllDisplayedSelectionActive = false
    @Published var deselectedItemsFromAll: Set<URL> = []

    func selectedCount(displayedPhotos: [PhotoItem]) -> Int {
        if isAllDisplayedSelectionActive {
            return max(0, displayedPhotos.count - deselectedItemsFromAll.count)
        }
        return selectedItems.count
    }

    func selectedURLs(displayedPhotos: [PhotoItem]) -> [URL] {
        if isAllDisplayedSelectionActive {
            let excluded = deselectedItemsFromAll
            return displayedPhotos.map(\.url).filter { !excluded.contains($0) }
        }
        return Array(selectedItems)
    }

    func selectedURLsInDisplayOrder(displayedPhotos: [PhotoItem]) -> [URL] {
        let orderedURLs = displayedPhotos.map(\.url)
        let orderIndex = Dictionary(uniqueKeysWithValues: orderedURLs.enumerated().map { ($1, $0) })
        return selectedURLs(displayedPhotos: displayedPhotos).sorted {
            (orderIndex[$0] ?? Int.max) < (orderIndex[$1] ?? Int.max)
        }
    }

    func isSelected(_ url: URL) -> Bool {
        if isAllDisplayedSelectionActive {
            return !deselectedItemsFromAll.contains(url)
        }
        return selectedItems.contains(url)
    }

    func clear() {
        selectedItems.removeAll()
        deselectedItemsFromAll.removeAll()
        isAllDisplayedSelectionActive = false
    }

    func selectAllDisplayed() {
        selectedItems.removeAll()
        deselectedItemsFromAll.removeAll()
        isAllDisplayedSelectionActive = true
    }

    func selectSingle(_ url: URL) {
        selectedItems = [url]
        deselectedItemsFromAll.removeAll()
        isAllDisplayedSelectionActive = false
    }

    func add(_ url: URL) {
        if isAllDisplayedSelectionActive {
            deselectedItemsFromAll.remove(url)
        } else {
            selectedItems.insert(url)
        }
    }

    func remove(_ url: URL) {
        if isAllDisplayedSelectionActive {
            deselectedItemsFromAll.insert(url)
        } else {
            selectedItems.remove(url)
        }
    }

    func remove(_ urls: Set<URL>) {
        if isAllDisplayedSelectionActive {
            deselectedItemsFromAll.formUnion(urls)
        } else {
            selectedItems.subtract(urls)
        }
    }

    func toggle(_ url: URL) {
        if isAllDisplayedSelectionActive {
            if deselectedItemsFromAll.contains(url) {
                deselectedItemsFromAll.remove(url)
            } else {
                deselectedItemsFromAll.insert(url)
            }
        } else if selectedItems.contains(url) {
            selectedItems.remove(url)
        } else {
            selectedItems.insert(url)
        }
    }

    func selectedSetForCurrentDisplay(displayedPhotos: [PhotoItem]) -> Set<URL> {
        Set(selectedURLs(displayedPhotos: displayedPhotos))
    }

    func replaceExplicitSelection(with urls: Set<URL>) {
        selectedItems = urls
        deselectedItemsFromAll.removeAll()
        isAllDisplayedSelectionActive = false
    }
}
