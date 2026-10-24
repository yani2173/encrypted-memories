# Troubleshooting

## The app says the device is unsupported

Confirm the device runs OS 26.0 or later and supports Metal 3. The App Store cannot filter Metal 3 exactly, so installation alone is not proof of support. See [[Device and Feature Support|Device-and-Feature-Support]].

## Sign-in does not return to the app

- Finish the Proton browser flow in the same user session.
- Allow the browser to open Encrypted Memories when prompted.
- Reopen the app and retry once.
- Confirm the network is available.

## The library is still preparing

Large libraries can show usable media before all thumbnails, map locations, and search indexes finish. Keep the app in the foreground for the first load. Do not clear caches while a first load or backup pass is active unless you intend to rebuild them.

## Photos are missing from backup

- Check Photos permission.
- With limited access, review **Change selection…**.
- Resume a paused backup.
- On the Backup page, open **Photos not backed up**. It names the reason for each photo. Select **Try again** for the photos that you can fix.
- On iPhone and iPad, remember that the operating system schedules background work.
- A photo you deleted in the app before its upload is excluded on purpose. Find it under **Excluded from
  Backup** in the Backup settings and choose **Back Up Again**.

## Backup shows Waiting for Wi-Fi

**Use Cellular Data** is off, and the device uses cellular data or Personal Hotspot. Connect to Wi-Fi, or turn on **Use Cellular Data** on the Backup page.

## The Map tab or sidebar item is missing

**Map and Places** is off. Turn it on in Settings under **Privacy**.

## Merging duplicates did not free storage

Merged copies move to Recently Deleted. Storage is freed only when Recently Deleted is emptied. See [[Duplicates|Duplicates]].

## A search scope is missing

Smart Search exposes only scopes that Apple Vision reports as supported and that have an available index. Check indexing status in Settings. A Neural Engine is not a general requirement.

## Search suggestions do not appear

Suggestions appear after the library and its thumbnails finish loading. The app builds them only while it is idle, so leave the search field empty and keep the app in the foreground. Photo-content suggestions also need the search model and a finished index; until then, Search shows a short note. A large library can need several minutes for the first build. Later restarts show the saved suggestions at once.

## Cached media is unavailable offline

Only media already present in the configured encrypted cache can open offline. Reconnect and open or cache the media before the next offline period.

If a problem is reproducible after these checks, use [[Support and Feedback|Support-and-Feedback]].
