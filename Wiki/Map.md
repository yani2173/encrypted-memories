# Map

The Map groups library items by their encrypted location metadata.

## What you see

- Individual photos at close zoom levels.
- Adaptive clusters when many photos share an area.
- A cluster series that opens the matching media in timeline order.
- Place names when the platform can resolve them.

Only media with usable location information appears. An empty Map does not mean the library is empty.

## Platform presentation

- **iPhone and iPad:** Open the **Map** tab and tap a marker or cluster.
- **Mac:** Select **Map** in the sidebar. The map stays beside the native sidebar and opens media in the shared viewer.

The local location index is account-scoped and encrypted at rest. Apple MapKit provides the native map surface and the place names. To resolve a place name, the app sends the location coordinates to Apple.

## Map and Places setting

**Map and Places** is on by default. Find it in Settings under **Privacy**. When you turn it off, maps and place names stop contacting Apple, and the Map tab (iPhone and iPad) or the Map item in the sidebar (Mac) disappears. Coordinates remain encrypted on this device. See [[Settings, Cache, and Privacy|Settings-Cache-and-Privacy]].

After you opened the Map once on a device, the app loads the map area it opens at while the app starts, so the Map appears without a grey background. Like opening the Map, this requests the map tiles of that area from Apple. Signing out resets it.
