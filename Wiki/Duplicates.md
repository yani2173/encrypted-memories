# Duplicates

Duplicates finds identical copies of a photo or video in your library and merges them. Identical means the same bytes and the same details. The details are capture time, place, camera, pixel size, duration, and file type. The file name does not count.

## Open Duplicates

- **iPhone and iPad:** Open **Collections**, then **Duplicates** in the **Utilities** section.
- **Mac:** Select **Duplicates** in the sidebar, above **Recently Deleted**.

The badge shows how many copies **Merge All** would move to Recently Deleted. The badge appears after the check of this launch has finished and every group passed the check. Before that, there is no badge.

## The check

Duplicates checks every candidate group before it shows a result. While the check runs, the screen shows **Checking duplicates** and a progress indicator. After the first step, the indicator shows a percentage. The screen shows no group yet. **Merge All** is dimmed. When the check ends, the screen shows only the final groups.

The app does not store the result of the check. After each launch, the first time that you open Duplicates, the app checks again. On a large library, this can take a while.

If the app still builds its index of your library, the screen shows **Still checking your library. More duplicates can appear.** above the groups. If no group exists yet, the screen shows **Checking Your Library**.

If the app cannot read some photos, the screen says how many photos could not be checked. If the check does not finish, the screen says **The library check did not finish.** and offers **Try again**. If the app cannot read the library, the screen says **The duplicates could not be loaded.** and offers **Try again**.

## Read a group

Each group shows the identical copies of one photo. The group header shows the capture date. Each copy shows its file size. Below the group, the app shows the space that the group frees once Recently Deleted is emptied, for example **Merge frees 2.1 MB**.

One copy of each group stays. The group tells you which one and why, for example **Stays: favorite** or **Stays: in one of your albums**. The copy that stays keeps its favorites and albums.

The app picks the copy that stays from facts on the Proton server only: shared, in one of your albums, favorite, then the oldest capture date. What this device backed up does not count. Every device therefore keeps the same copy.

Select **Merge** in the group header to merge one group. Each copy also has a menu with **Keep This Copy**; on iPhone and iPad, press and hold the copy.

Tap or click a copy to open it in the viewer. The viewer shows the other copies of the group in a filmstrip. Use **Keep This Copy** to choose the copy that stays, and **Merge** to merge the group.

## Merge All

**Merge All** merges every group. It is dimmed while the check runs.

Select **Merge All**. An alert asks you to confirm. If every group was checked, the title shows the number of copies. If a group could not be checked, the title says **Merge Duplicates?** and shows no number. Select **Merge** to continue or **Cancel** to stop. After you select **Merge**, Merge All checks that group first and shows **Checking duplicates** with **Stop**.

The app merges the groups in batches. The screen shows **Merging Duplicates** and a count, for example **320 of 1,404 groups**. Select **Stop** to stop after the batch that runs. The app then shows **Merging stopped. X of Y groups were merged.** The groups that were not merged stay in the list. Start Merge All again to merge them.

On iPhone and iPad, Merge All pauses when the app goes to the background and continues when you return to the app. It does not continue after the app is quit.

## What happens to the merged copies

Merging moves the other copies of each group to [[Recently Deleted|Recently-Deleted]]. You can restore them from there.

Merging alone does not free storage in Proton Drive. Storage is freed only when Recently Deleted is emptied. The screen shows this, for example **Merging all frees 3.4 GB once Recently Deleted is emptied.**

## Copies that stay

Some copies stay in the library after a merge. The app then tells you how many duplicates it kept, and why, for example:

- It is shared with others.
- The backup of this device still needs it.
- An edit is still being backed up.
- It has an extra file that would be lost. An extra file is, for example, a Live Photo video or the original of an edited photo.
- Its date, place, or other details differ.
- It could not be read. Try again later.

If the copy that you chose to keep cannot be read, the group is not merged. The app shows **Not Merged**: **The photo to keep could not be read. Choose another one or try again later.**

## If a merge fails

If some groups do not merge, the app shows **Merge Failed** and asks you to check your connection and try again.

If no group of a batch can be merged, for example without a connection, Merge All stops and shows **Merging stopped. X of Y groups were merged.**
