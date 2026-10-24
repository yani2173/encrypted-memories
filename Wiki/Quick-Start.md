# Quick Start

## 1. Check your device

Encrypted Memories requires:

- iOS 26.0 or later, iPadOS 26.0 or later, or macOS 26.0 or later.
- A GPU that reports Metal 3 support.
- An existing Proton account.

Check [[Device and Feature Support|Device-and-Feature-Support]] before installation. The App Store cannot express the exact Metal 3 requirement, so a small number of older devices can install the app but will see a friendly unsupported-device screen.

## 2. Sign in

Open Encrypted Memories and select **Sign in with Proton**. Authentication continues in Proton’s browser flow. The app does not ask for or store your Proton password.

After the browser returns to the app, wait for the initial library load. Large libraries can continue preparing thumbnails and search indexes in the background.

## 3. Learn the native layout

| Area | iPhone and iPad | Mac |
|---|---|---|
| Main navigation | Photos, Collections, Map, and Search tabs | Sidebar with library filters, albums, shared albums, Map, Duplicates, and Recently Deleted |
| Settings | Account button in the Photos toolbar | **Encrypted Memories → Settings…** or the sidebar Settings item |
| Multi-select | Select button and native bottom actions | Selection controls in the library toolbar |
| Viewer | Full-screen swipe and native touch gestures | Full-window viewer with keyboard, mouse, trackpad, and toolbar controls |

The layout differs, but the library, albums, viewer, map, backup, cache, and search behavior comes from the same shared feature core.

## 4. Browse and protect your library

- Open [[Library|Library]] to browse photos and videos.
- Use [[Collections|Collections]] for Favorites, media types such as Videos, Live Photos, or Screenshots, albums, and Recently Deleted.
- Open [[Duplicates|Duplicates]] to find identical copies and merge them.
- Enable [[Backup and Photo Library Sync|Backup-and-Album-Sync]] if you want to back up the Apple Photos library.
- Use [[Album Sync|Album-Sync]] if you want to mirror selected Apple Photos albums.
- Open [[Smart Search|Smart-Search]] to build a private on-device search index.

## 5. Check the privacy defaults

Until you choose otherwise, backups do not use cellular data, shared and exported copies have their location removed, the app preview is blurred in the App Switcher (iPhone and iPad), and Map and Places is on. Change these in Settings under **Privacy** and on the **Backup** page. See [[Settings, Cache, and Privacy|Settings-Cache-and-Privacy]].

## 6. Know what stays local

Local thumbnails, previews, originals, cached Proton account data, location data, and search indexes are encrypted at rest. The library and backup bookkeeping databases hold no photos; FileVault or iOS Data Protection protects them. Search queries and photos are not sent to a separate search service. Decrypted originals are created only for an explicit share, drag, or export operation.

Continue with [[Settings, Cache, and Privacy|Settings-Cache-and-Privacy]] or [[Troubleshooting|Troubleshooting]].
