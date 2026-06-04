# PictureViewer

A sandboxed macOS SwiftUI photo browser for navigating large local image libraries. Built with Swift 6 concurrency, the `@Observable` macro, Vision-based face clustering, and an embed-only metadata write policy.

## Features

- **Recursive folder browsing** with a thumbnail grid, sized via a toolbar slider (80–320px).
- **Multi-folder selection** — pick several folders at once; results are combined into a single view, deduplicated by basename.
- **Fast launches** — folder contents are persisted as JSON snapshots in Application Support so the grid populates without re-scanning. Re-scans can be deferred or run as background reconciliation.
- **Parallel scanner** — N detached workers driven by an actor-based `ScanCoordinator`, with worker count chosen from active CPU cores (clamped 2…32).
- **Two-tier thumbnail cache** — `NSCache` in memory + JPEG on disk at a 512px canonical size, keyed by SHA-256 of the file path and validated against source modification time.
- **Three-stage thumbnail load** — persistent cache, then a fast ImageIO low-res preview, then a high-quality QuickLook thumbnail.
- **Photo viewer** with full-screen, maximized, or windowed display modes; preserves window tabbing; supports in-memory rotation preview and persisting rotation to disk via a pixel rewrite that preserves embedded metadata.
- **Bulk operations** in selection mode: edit IPTC keywords, rotate left/right, apply rotations to disk, move to Trash. Each operation runs in its own progress sheet with per-file success/failure indicators and a retry path.
- **Regex search** across filenames and embedded metadata (EXIF, TIFF, IPTC, PNG), with an immediate filename-only pass on the main actor and a debounced metadata-aware pass on a background task.
- **Sort modes** — name ascending/descending, file date, image date (EXIF/TIFF).
- **Face recognition (opt-in)** — Vision `VNDetectFaceRectangles` per scanned image, DBSCAN-style clustering via `VNGenerateImageFeaturePrintRequest` distance, and a People browser with rename / merge / split.
- **Session restore (opt-in)** — remembers the active folder and any open photo windows (including tabbed/background ones) so they reopen on next launch.
- **Password protection (opt-in)** — gates the UI behind LocalAuthentication (Touch ID or macOS password).
- **Embed-only metadata writes** — keyword and rotation writes only embed into image files; failures surface a user-facing alert offering to re-grant folder access. No silent sidecar fallback.
- **Metadata repair** — a per-photo "Repair metadata" command reads any existing sidecar (adjacent or app-support) and re-embeds its contents into the image, then deletes the sidecar.
- **Telemetry** — a small actor counts files found, batches yielded, thumbnails generated, and metadata reads, logged via Apple unified logging under the `com.example.PictureViewer` subsystem.

## Requirements

- macOS with a Swift 6 toolchain (the project relies on the `@Observable` macro, `@MainActor`-isolated observable classes, and modern structured concurrency).
- Xcode with SwiftUI, AppKit, Vision, ImageIO, CryptoKit, LocalAuthentication, and QuickLookThumbnailing available.
- App is sandboxed; folder access uses security-scoped bookmarks.

## Build and run

Open `PictureViewer.xcodeproj` in Xcode and run the **PictureViewer** scheme. On first launch:

1. If password protection is enabled (default), authenticate with Touch ID or your macOS password.
2. Click **Choose Folder…** in the toolbar and pick one or more folders containing photos.
3. The scanner streams thumbnails into the grid as it finds files; subsequent launches reuse the cached snapshot.

## Settings

All preferences live in **Picture Viewer → Settings…** and are persisted via `@AppStorage`:

| Key | Default | Effect |
| --- | --- | --- |
| `photoDisplayMode` | `fullScreen` | How the photo viewer window opens: full screen, maximized window, or regular window |
| `saveOpenWindows` | `false` | Persist the active folder and open photo windows across launches |
| `requirePasswordAtLaunch` | `true` | Gate the UI behind LocalAuthentication |
| `deferAtLaunchBackgroundWork` | `true` | At launch, populate from the cached snapshot and skip the re-scan / thumbnail cache sweep |
| `enableFaceRecognition` | `false` | Run Vision face detection and clustering on scanned and restored photos |
| `disableAutoRestoreWindows` | `true` | Diagnostic toggle to skip reopening saved photo windows even when `saveOpenWindows` is on |
| `disableThumbnailLoadingAtLaunch` | `false` | Diagnostic toggle to skip thumbnail generation in `ThumbnailView` |
| `sortMode` | `0` (Name ↑) | Active sort mode for the grid |

The Performance tab also surfaces detected CPU information and the scanner thread count.

## Architecture

All Swift sources live in `PictureViewer/PictureViewer/`.

### App entry

- **`PictureViewerApp.swift`** — `@main` App declaring four scenes:
  - main `WindowGroup` → `ContentView` (auth-gated)
  - `WindowGroup(id: "photo-viewer", for: URL.self)` → `FullScreenPhotoView`
  - `WindowGroup(id: "people", for: Bool.self)` → `PeopleView`
  - `Settings` → `SettingsView`
  - Installs a `willTerminateNotification` observer that snapshots open photo windows when `saveOpenWindows` is on, or clears them otherwise.
- **`AuthenticationManager.swift`** / **`LockView.swift`** — `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` and the locked UI.

### Library and scanning

- **`PhotoLibrary.swift`** — `@MainActor @Observable` model holding the photo list, folder URL, scan timing, and the active scan task. Implements the parallel scanner: `scanStream(folder:batchSize:)` runs N detached workers coordinated by the `ScanCoordinator` actor, with a `FileNameDeduper` actor for basename deduplication. Persists per-folder snapshots in Application Support (`persistCachedSnapshot` / `loadCachedSnapshot`) and supports combined multi-folder snapshots.

### Thumbnails

- **`ThumbnailGenerator.swift`** — `QLThumbnailGenerator` wrapper throttled by `AsyncLimiter` (capacity = scanner worker count). Also defines the `AsyncLimiter` actor used by face processing and metadata reads.
- **`ThumbnailCache.swift`** — two-tier cache: `NSCache` for memory (sized to ~1/8 of physical RAM, capped at 1GB) and on-disk JPEG at the 512px canonical size. Validates freshness via modification dates and supports `sweepStale(olderThanDays:)`.
- **`ThumbnailView.swift`** — three-stage load (cache → ImageIO low-res preview → QuickLook high-res) plus an inline IPTC/EXIF/TIFF keyword reader for the badge and caption row.

### Metadata and search

- **`MetadataCache.swift`** — concurrent-dictionary caches for image date, file mod date, and a concatenated "candidate" string of filename + EXIF/TIFF/IPTC/PNG fields used for search. Reads are throttled by an `AsyncLimiter`.
- **`ContentView.scheduleSort`** — runs a quick filename-only filter on the main actor, then debounces 200ms before doing a metadata-aware regex match on a background task.

### Faces

- **`FaceProcessor.swift`** — singleton coordinating Vision face detection per file. Writes cropped face JPEG thumbs to `~/Library/Application Support/PictureViewer/faces/`. Implements a DBSCAN-style clustering pass using `VNGenerateImageFeaturePrintRequest` distance.
- **`FaceDatabaseActor.swift`** — actor wrapping the `FaceDatabase` (records, persons, personNames) persisted to `face-db.json` in Application Support. Exposes person rename / merge / split operations.
- **`PeopleView.swift`** + **`PersonDetailView.swift`** — UI for browsing detected people, renaming them, merging, and splitting selected faces into a new person.

### Photo viewer

- **`PhotoDetailView.swift`** — `FullScreenPhotoView` honours `photoDisplayMode`, supports in-memory rotation preview, and persists rotation to disk by rewriting the image with CG while preserving embedded metadata. Sets `window.representedURL` so global window snapshotting can discover open photo windows even when tabbed or in the background.

### Session persistence and AppKit interop

- **`WindowStateStore.swift`** — `NSLock`-protected singleton that stores the active folder's security-scoped bookmark and the list of open photo URLs. `consumeLaunchRestoration()` ensures only the first `ContentView` at launch hydrates from the saved session. `snapshotTabs(of:)` captures all tabs in a window group on close.
- **`WindowAccessor.swift`** — `NSViewRepresentable` exposing the underlying `NSWindow` to SwiftUI; installs a per-window `willCloseNotification` observer that triggers tab snapshotting.

### Other

- **`SettingsView.swift`** — General + Performance tabs.
- **`Telemetry.swift`** — actor counting files/batches/thumbnails/metadata reads; logs scan duration and files-per-second.

## Notable design decisions

- **Embed-only writes.** Keyword and rotation writes only modify the image file itself. If `CGImageDestinationCreateWithURL` or `CGImageDestinationFinalize` fails, the app posts an `.embedWriteFailed` notification and shows an alert offering to re-grant folder access — it does **not** silently write a sidecar. Sidecars are read and re-embedded only by the explicit "Repair metadata" command.
- **Snapshot-first launches.** `deferAtLaunchBackgroundWork` defaults to `true` so the UI is populated from the persisted snapshot without a re-scan. A low-priority background re-scan can be enabled to reconcile on-disk state.
- **Concurrency-first IO.** Thumbnail generation, metadata reads, and face processing each go through an `AsyncLimiter` sized to the scanner worker count, so the app exploits available cores without thrashing slow disks.
- **Security-scoped folder access.** Multi-folder selection stores an array of bookmarks under `kLastFolderBookmarks`, retaining the single-bookmark `kLastFolderBookmark` for backward compatibility. The active resolved URL is kept on the `ContentView` for write paths.

## Storage locations

- **Snapshots, sidecars, face data**: `~/Library/Application Support/PictureViewer/`
  - `*.json` — per-folder photo path snapshots
  - `combined_snapshot.json` — combined snapshot for multi-folder views
  - `sidecars/` — app-support sidecar fallback (used by `writeSidecar` only)
  - `faces/` — cropped face thumbnails
  - `face-db.json` — face records, person clusters, person names
- **Thumbnails**: `~/Library/Caches/PictureViewer/Thumbnails/`
- **Preferences**: `UserDefaults` under the app's bundle identifier.

## Logging

All logs use the unified logging subsystem `com.example.PictureViewer` with categories such as `app`, `scan`, `ui`, `thumbnail-cache`, `thumbnail-generator`, `thumbnail-view`, `metadata`, `face-db`, `window-state`, `auth`, and `telemetry`. Filter in Console.app or `log stream --predicate 'subsystem == "com.example.PictureViewer"'`.
