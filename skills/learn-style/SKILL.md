---
name: learn-style
description: Learn a photographer's editing style from photos they already edited in Capture One, and save it as a named style the edit skill applies. Use when asked to learn, capture or copy a style or look.
---

# Learn a style

Writes `~/.c1/styles/<name>.md`: per scene, a description, the setting ranges the photographer uses, and reference variant ids. The `edit` skill reads it when asked to edit "in <name> style". This skill only reads photos; it writes no variant.

## Steps

1. **Name and scope.** Ask for the style's name (lowercase, hyphens: `wedding-film`) and where its examples are: a collection (`c1 collections`), a rating, or the current selection. If `~/.c1/styles/<name>.md` exists, read it and ask whether to replace it or add to it.
2. **Find the edited photos.** `c1 list` with that scope and `edited: true`, paging with `after` until `next` is absent. Fewer than about 8: say the style will be thin and ask for more examples.
3. **See them.** `c1 contact_sheet` with the same filters (`fillMissing: true` if tiles are missing). Group the photos by scene: light, setting and subject that call for different treatment (golden-hour portrait, overcast landscape, night street). Two to six scenes is typical; a scene needs at least 3 photos.
4. **Read their settings.** `c1 get` with `changed: true` for each scene's photos, up to 100 ids per call. Per scene, collect each field the photographer changed in most of its photos: the minimum and maximum, and what stays constant (a film curve, black and white, a curve shape). Note fields that depend on the camera, such as white balance, as values to judge per photo, not to copy.
5. **Look at the extremes.** `c1 preview` two or three photos per scene, including the ones at the ends of a range, to tie each number to what it looks like.
6. **Write the file** in the format below, then show it to the photographer and adjust it with them.

Done when every scene has a description, ranges and at least 3 reference ids, and the photographer has seen the file.

## File format

```markdown
# Style: <name>

Learned <date> from <scope>, <n> edited photos in <document name>.

## Scene: <short name>

<One paragraph: the light, setting and subject this covers, and the look the edits create.>

| Field | Range | Note |
|---|---|---|
| adjustments.exposure | 0.2 – 0.6 | brighter than metered |
| adjustments.curves.luma | [[0,8],[25,22],[75,80],[100,96]] | faded blacks, soft highlights |

Reference variants: 1234, 1240, 1311 (the most typical first).
```

Field names are the paths `c1 set --help` lists. Keep only fields that define the look; leave out what Capture One sets per camera and what varies without a pattern.
