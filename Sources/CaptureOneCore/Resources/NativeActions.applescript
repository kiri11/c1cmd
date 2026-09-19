-- Explicit editing commands. No arbitrary script or object specifier is accepted.
on nativeAction(docName, variantId, scopeName, layerNumber, elementNumber, expectedPath, expectedFields, expectedValues, expectedLayerNames, actionName, argNames, argValues)
    -- Reuse the immediate state check without issuing a property write.
    my nativeApply(docName, variantId, scopeName, layerNumber, elementNumber, expectedPath, expectedFields, expectedValues, expectedLayerNames, {}, {})
    set d to my checkedDocument(docName)
    tell application "/Applications/Capture One.app" to set v to variant id variantId of d
    set t to my nativeTarget(v, scopeName, layerNumber, elementNumber)
    set amountValue to my nativeArgument("amount", argNames, argValues, 0)
    set nameValue to my nativeArgument("name", argNames, argValues, "")
    tell application "/Applications/Capture One.app"
        if actionName is "mask.people" then
            set areaNames to my nativeArgument("areas", argNames, argValues, {})
            set areaValues to {}
            repeat with areaName in areaNames
                if areaName as text is "body skin" then set end of areaValues to body skin
                if areaName as text is "face skin" then set end of areaValues to face skin
                if areaName as text is "eyebrows" then set end of areaValues to eyebrows
                if areaName as text is "lips" then set end of areaValues to lips
                if areaName as text is "hair" then set end of areaValues to hair
                if areaName as text is "iris and pupil" then set end of areaValues to iris and pupil
                if areaName as text is "sclera" then set end of areaValues to sclera
                if areaName as text is "clothes" then set end of areaValues to clothes
            end repeat
            set separateValue to my nativeArgument("separateLayers", argNames, argValues, false)
            create people mask v areas areaValues separate layers separateValue
        else if actionName is "layer.create" then
            set kindValue to my nativeArgument("kind", argNames, argValues, "adjustment")
            if kindValue is "adjustment" then make new layer at v with properties {name:nameValue, kind:adjustment}
            if kindValue is "filled" then make new layer at v with properties {name:nameValue, kind:filled}
            if kindValue is "clone" then make new layer at v with properties {name:nameValue, kind:clone}
            if kindValue is "heal" then make new layer at v with properties {name:nameValue, kind:heal}
            if kindValue is "subject mask" then make new layer at v with properties {name:nameValue, kind:subject mask}
            if kindValue is "background mask" then make new layer at v with properties {name:nameValue, kind:background mask}
        else if actionName is "layer.delete" then
            if kind of t is background then error "Cannot delete the image layer."
            delete t
        else if actionName is "mask.clear" then
            clear mask t
        else if actionName is "mask.invert" then
            invert mask t
        else if actionName is "mask.fill" then
            fill mask t
        else if actionName is "mask.rasterize" then
            rasterize mask t
        else if actionName is "mask.feather" then
            feather mask t amount amountValue
        else if actionName is "mask.refine" then
            refine mask t amount amountValue
        else if actionName is "mask.copy" then
            set sourceNumber to my nativeArgument("sourceLayer", argNames, argValues, 0)
            copy mask layer sourceNumber of v to layer t
        else if actionName is "luma.clear" then
            clear luma range t
        else if actionName is "style.apply" then
            apply style t named nameValue
        else if actionName is "color.create" then
            make new advanced color correction at color editor settings of t
        else if actionName is "color.delete" then
            delete t
        else if actionName is "dehaze.pick" then
            set pointValue to my nativeArgument("point", argNames, argValues, {})
            pick dehaze t at pointValue
        else if actionName is "dehaze.recalculate" then
            recalculate dehaze t
        else if actionName is "lens.reset" then
            reset t
        else
            error "Unknown native action."
        end if
    end tell
    return true
end nativeAction

on nativeArgument(argName, argNames, argValues, defaultValue)
    repeat with i from 1 to count of argNames
        if item i of argNames is argName then return item i of argValues
    end repeat
    return defaultValue
end nativeArgument

-- Intentionally separate from generated nativeReadField and nativeApply.
-- Keep this explicit order matched to Recipes.oracleFields; live tests compare
-- every supported field against both paths before registering a payload.
on nativeRecipeOracle(docName, variantId, expectedParent)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docName)
        set v to variant id variantId of d
        if (POSIX path of (path of parent image of v as text)) is not expectedParent then error "Recipe parent image changed."
        set a to adjustments of v
        set observed to {exposure of a as real, temperature of a as real, tint of a as real, brightness of a as real, contrast of a as real, saturation of a as real, highlight adjustment of a as real, shadow recovery of a as real, white recovery of a as real, black recovery of a as real, clarity amount of a as real, clarity structure of a as real, sharpening amount of a as real, sharpening radius of a as real, sharpening threshold of a as real, noise reduction luminance of a as real, noise reduction color of a as real}
        set recipeCurvePoints to {}
        repeat with p in every curve point of rgb curve of a
            set end of recipeCurvePoints to (brightness of p as real)
            set end of recipeCurvePoints to (amount of p as real)
        end repeat
        set end of observed to recipeCurvePoints
        set recipeCurvePoints to {}
        repeat with p in every curve point of luma curve of a
            set end of recipeCurvePoints to (brightness of p as real)
            set end of recipeCurvePoints to (amount of p as real)
        end repeat
        set end of observed to recipeCurvePoints
        set recipeCurvePoints to {}
        repeat with p in every curve point of red curve of a
            set end of recipeCurvePoints to (brightness of p as real)
            set end of recipeCurvePoints to (amount of p as real)
        end repeat
        set end of observed to recipeCurvePoints
        set recipeCurvePoints to {}
        repeat with p in every curve point of green curve of a
            set end of recipeCurvePoints to (brightness of p as real)
            set end of recipeCurvePoints to (amount of p as real)
        end repeat
        set end of observed to recipeCurvePoints
        set recipeCurvePoints to {}
        repeat with p in every curve point of blue curve of a
            set end of recipeCurvePoints to (brightness of p as real)
            set end of recipeCurvePoints to (amount of p as real)
        end repeat
        set end of observed to recipeCurvePoints
        return observed & {film grain type of a as text, film grain impact of a as real, film grain granularity of a as real, vignetting method of a as text, vignetting amount of a as real}
    end tell
end nativeRecipeOracle
