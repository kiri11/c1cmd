---
name: crop-policy
description: Write or change the photographer's crop policy, ~/.c1/crop-policy.md, which the edit skill follows for every crop and rotation. Use when asked to set, show or change how photos are cropped or straightened.
---

# Crop policy

The policy lives in `~/.c1/crop-policy.md`. The `edit` skill reads it before any crop or rotation, and uses the default below when the file is missing.

## Steps

1. **Read the current policy**: the file if it exists, else the default below. Show it to the photographer.
2. **Ask what to change**, one topic at a time: ratios per orientation, when to straighten, keystone, how tight to crop, and rules of composition. Offer the default's wording as a starting point. Keep each rule a short imperative with its exception.
3. **Write the file** with the photographer's rules, keeping the default's sections for anything they did not change. Write it whole each time; it is short.
4. **Read it back** to the photographer.

Done when the file exists and the photographer has confirmed it.

## Default policy

```markdown
# Crop policy

- Crop horizontal photos 3:2 and vertical photos 3:4 (width:height).
- Rotate first, then read cropBounds again. Start from the largest rectangle of the ratio inside cropBounds; tighten only when that improves the composition.
- Straighten horizons unless the tilt is intentional, which usually means more than 15°.
- No keystone correction by default.
- Preserve interesting composition. Don't cut heads or limbs.
- Keep distracting elements out of edges and corners.
- Leave room in front of a gaze or motion.
- Place horizons off-centre, unless symmetry or a reflection justifies the middle.
- Don't let a leading line exit through a corner.
- Flag ambiguous cases for the photographer's review.
```

A ratio applies to the crop's pixel size in `c1 get` (`variant.crop` is `[centre x, centre y, width, height]`): 3:2 means width = 1.5 × height.
