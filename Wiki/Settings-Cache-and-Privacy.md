# Settings, Cache, and Privacy

## iPhone and iPad

Open the **Photos** tab and select the account button. Settings shows your account and storage, optional tips, and the **Features** Smart Search, Backup, and Album Sync. Each feature opens its own page. Its row shows the current state, for example **On**, **Paused**, or **3 albums**. Below follow **Privacy**, **Labs**, the cache controls, support-report export, sign out, and build information.

## Mac

Open **Encrypted Memories → Settings…**. Native tabs separate Proton Account, Support, Library, Smart Search, Backup, Privacy, and Labs.

## Privacy

The **Privacy** page (iPhone and iPad) or tab (Mac) has these switches:

| Switch | Default | What it does |
|---|---|---|
| **Map and Places** | On | When off, maps and place names stop contacting Apple. The Map tab (iPhone and iPad) and the Map item in the sidebar (Mac) disappear. Coordinates remain encrypted on this device. |
| **Remove location when sharing** | On | When on, shared and exported copies have no standard GPS metadata. Originals remain unchanged. |
| **Blur App Preview** | On | iPhone and iPad only. Hides app content in the App Switcher. |

The page also links to the Privacy Policy.

On the Mac, **Report a problem** is at the bottom of the Privacy tab. It exports the support report.

**Use Cellular Data** for backups is on the Backup page. It is off by default. See [[Backup and Photo Library Sync|Backup-and-Album-Sync]].

These defaults apply when you did not choose a value yet. A choice that you saved stays.

## Labs

Labs is the place to try new features before they are finished. Each feature has its own switch and stays off until you turn it on. Labs features can still change or go away. Some appear only in TestFlight builds. When nothing is ready to try, Labs says so.

Signing out turns every Labs feature off.

## Cache controls

Encrypted Memories keeps encrypted thumbnails, previews, originals, metadata, and derived indexes in account-scoped local storage. Clearing a cache removes local copies; it does not delete remote Proton Drive photos.

The app can rebuild derived thumbnails and search indexes from the remote library. This can temporarily increase network and background activity.

When the device is almost full, the app stops saving new offline copies of originals, previews, and videos. When hardly any space is left, it also deletes these copies and pauses background work that writes a lot, such as indexing. Grid thumbnails stay. Settings shows a short note while this applies. Everything resumes on its own once there is space again.

## Privacy boundaries

- Proton authentication happens through the browser flow.
- Credentials use the platform Keychain with device-only accessibility.
- Local photo and search data is encrypted at rest.
- Search queries are not sent to a separate search service.
- Place names in the viewer, on the Map, and in search suggestions come from Apple MapKit. The app sends location coordinates to Apple for this. For search suggestions, it sends only the rounded center of a group of photos, precise to about 1 km. These requests contain no photos, file names, or search text. Turn off **Map and Places** to stop these requests.
- Release builds do not write file debug logs. Runtime-gated unified logging is disabled unless explicitly enabled for a local investigation.
- Support reports must be reviewed before sharing. Never attach passwords, API keys, private links, or photo content to GitHub.

Signing out removes account-scoped local state after active work has stopped. Remote Proton Drive content remains unchanged.
