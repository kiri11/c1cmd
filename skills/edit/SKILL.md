---
name: edit
description: Edit photos in Capture One with c1 - tone, color, curves, crop, rotation, layers, ratings - one photo or a batch in fan-out. Use when the photographer asks to edit, grade, crop, straighten or apply a style to photos open in Capture One.
---

# Edit photos with c1

`c1 <command> --help` is the contract for every command: arguments, ranges, results and errors. This skill is the craft and the rules c1 cannot enforce. If `c1` is missing or `doctor` fails, run the `setup` skill first.

## Rules c1 cannot enforce

- **Take turns.** While you edit, the photographer does not edit the same photos in Capture One, and you do not edit while they do. Say when you start and when you hand back.
- **One document.** Keep the one Catalog or Session open; do not ask to switch documents mid-edit.
- **`get` before deciding.** Read the variant's current values with `c1 get` before choosing any target. The photographer may have changed it since your last read.
- **`revert` is the undo.** `revert` restores the snapshot c1 took before its first write, by scope. `action variant.reset` applies Capture One's defaults and deletes c1's layers: it is not an undo.
- **Hand-drawn masks are the photographer's.** For a mask c1 cannot make (brush, gradient, radial, one subject among several), do not approximate one. Show the preview, describe the region by landmarks ("the sky above the ridge, left of the tree"), and ask the photographer to draw a layer with a unique name. Once they confirm, find it by that name in `get`'s `layers` and set its adjustments. c1's cached renders cannot see mask pixels, so pass `refresh: true` to the next `crop_preview` or `contact_sheet` with `fillMissing`.

## Before the first edit

1. `c1 doctor`: relay its warnings. On a Catalog without a fresh backup, ask for **File > Backup Catalog** first.
2. Find the photos: `c1 selection`, or `c1 list` with filters, or a `c1 contact_sheet` to see them.
3. Read the guides that apply:
   - **A named style** ("in my wedding style"): read `~/.c1/styles/<name>.md`. Match each photo to the scene that fits it and work toward that scene's setting ranges, looking at its reference variants with `preview` when unsure. No such file: ask, or offer the `learn-style` skill.
   - **Any crop or rotation**: read `~/.c1/crop-policy.md`; without it, use the default policy in the `crop-policy` skill.

## The editing loop

Per photo:

1. **Look.** `c1 preview` the photo and `c1 get` it. State the visual goal in one sentence.
2. **Pick one small group of related controls**: white balance; or exposure and contrast; or highlights and shadows; or a curve; or the color editor; or crop and rotation. Never everything at once.
3. **Set absolute targets.** Turn the goal into target values ("exposure 0.4", not "a bit brighter") and `c1 set` them. Every `set` reads the variant first, which costs about 1 s more per extra layer, so group fields into one call.
4. **Look again.** `c1 preview` and compare against the goal. Use `preview` with `region` and `scale` only for judgements at pixel level: sharpness, noise, halos, mask edges.
5. **Stop** when the goal is met, progress stalls, a capability limit is reached (a hand-drawn mask, a control c1 lacks), or after four passes. Then summarize the visible effect and the values you changed.

A result's `warnings` with `sent` and `stored` mean Capture One kept a different value: read it, do not resend. An `unknown` outcome means the write may or may not have happened: `get` again before anything else; never repeat the call blindly.

## Crops

Follow the crop policy. Rotate (and any keystone) first in its own `set`, then `get` again: rotation changes `cropBounds`, Capture One shrinks the crop to fit, and a crop is in pixels of the rotated canvas. Compare candidate crops side by side with `c1 crop_preview`. It renders only Capture One's default crop, the largest centred rectangle, so a candidate beyond it fails; try that one with `set`, `preview` and `revert` (scope `geometry`).

## Fan-out for many photos

For a batch, run one subagent per photo, at most about 4 at once. Give each the photo id, the goal, the style and crop policy paths, and this skill's rules; each runs the loop on its photo only and returns its summary. c1 queues their calls to Capture One, so they never collide. When all are done, make one `c1 contact_sheet` of the batch (`ids`, and `fillMissing: true` for photos Capture One has not shown in its browser, about 2.4 s per gap), review it for consistency across the set, and fix outliers with the loop.

## Hand back

Tell the photographer which photos changed and how, and that `revert` (all, or a scope) returns each to its state before your first write. Then stop editing until they hand back.
