-- Handlers.applescript: Central AppleScript handlers for Capture One 16.8.5.30
-- Returns user-defined records exclusively with non-reserved key names.

-- docRef is {document ID, ID of the Catalog's stored All Images collection or missing value}.
on checkedDocument(docRef)
    tell application "/Applications/Capture One.app"
        if (count of documents) is not 1 then error "Exactly one open document is required." number -27001
        set d to first document
        if (id of d as text) is not item 1 of docRef then error "Active document changed before dispatch." number -27001
        return d
    end tell
end checkedDocument

-- Capture One resolves "variant id X of document" only inside the current collection.
-- Variants resolve through All Images when the Catalog's stored ID names it, otherwise
-- through folder favorites (a Session's system folders come first), then through the
-- current collection. Deleting through All Images or a folder removes the variant;
-- deleting through an album only removes it from the album.
on variantRoutes(docRef, d)
    tell application "/Applications/Capture One.app"
        set allImagesId to item 2 of docRef
        if allImagesId is not missing value then
            -- One whose query confirms the stored ID in a single Apple Event.
            if exists (first collection of d whose id is allImagesId and kind is smart album and user is false) then return {collection id allImagesId of d, d}
            return {d}
        end if
        return (every collection of d whose kind is favorite) & {d}
    end tell
end variantRoutes

-- The variant through the first route that holds it, or missing value.
on foundVariant(routes, variantId)
    tell application "/Applications/Capture One.app"
        repeat with route in routes
            if exists variant id variantId of (contents of route) then return variant id variantId of (contents of route)
        end repeat
    end tell
    return missing value
end foundVariant

on requiredVariant(routes, variantId)
    set v to my foundVariant(routes, variantId)
    if v is missing value then error "Variant " & variantId & " is in neither the Catalog's All Images collection, a Session folder favorite nor the current collection." number -27004
    return v
end requiredVariant

on documentVariant(docRef, variantId)
    set d to my checkedDocument(docRef)
    return my requiredVariant(my variantRoutes(docRef, d), variantId as text)
end documentVariant

on assertParent(v, expectedPath)
    tell application "/Applications/Capture One.app"
        set actualPath to POSIX path of (path of parent image of v as text)
        if actualPath is not expectedPath then error "Variant parent image changed." number -27003
    end tell
end assertParent

on getAppAndDocInfo()
    tell application "/Applications/Capture One.app"
        set appVer to (version as text)
        set d to missing value
        try
            set d to current document
        end try
        if d is missing value then
            try
                set d to first document
            end try
        end if
        if d is missing value then
            return {appVersion:appVer, hasDocument:false, docName:missing value, docPath:missing value, docId:missing value, isSession:false, documentCount:(count of documents)}
        end if
        set dName to ""
        try
            set dName to (name of d as text)
        end try
        set dId to ""
        try
            set dId to (id of d as text)
        end try
        -- Capture One's path property may be the creation parent. Its ID is the
        -- actual Session directory (or database path on some builds).
        if dId does not start with "/" then error "Document ID is not an absolute path." number -27003
        set dPath to dId

        set isSess to false
        try
            set k to (kind of d as text)
            if k is "session" or k is "Session" then
                set isSess to true
            end if
        on error
            if dName ends with ".cosessiondb" or dId ends with ".cosessiondb" or dPath contains ".cosessiondb" then
                set isSess to true
            end if
        end try
        if dName ends with ".cosessiondb" or dId ends with ".cosessiondb" or dPath contains ".cosessiondb" then
            set isSess to true
        end if

        return {appVersion:appVer, hasDocument:true, docName:dName, docPath:dPath, docId:dId, isSession:isSess, documentCount:(count of documents)}
    end tell
end getAppAndDocInfo

-- Qualified by the independent legacy enumeration for Session and Catalog document,
-- album and selected scopes on 16.8.5.30. Every ID stays paired with its own summary.
on discoverFilteredVariantIDs(docRef, collectionName, selectedOnly, exactRating, minimumRating)
    set d to my checkedDocument(docRef)
    tell application "/Applications/Capture One.app"
        if collectionName is missing value or collectionName is "" then
            set scope to d
        else
            set scope to collection collectionName of d
        end if
        if exactRating is not missing value then
            if selectedOnly then
                set foundIDs to id of (every variant of scope whose selected is true and rating is exactRating)
            else
                set foundIDs to id of (every variant of scope whose rating is exactRating)
            end if
        else if minimumRating is not missing value then
            if selectedOnly then
                set foundIDs to id of (every variant of scope whose selected is true and rating is greater than or equal to minimumRating)
            else
                set foundIDs to id of (every variant of scope whose rating is greater than or equal to minimumRating)
            end if
        else
            if selectedOnly then
                set foundIDs to id of (every variant of scope whose selected is true)
            else
                set foundIDs to id of every variant of scope
            end if
        end if
        set textIDs to {}
        repeat with foundID in foundIDs
            set end of textIDs to foundID as text
        end repeat
        return textIDs
    end tell
end discoverFilteredVariantIDs

-- Discovery remains a single application enumeration; its internal progress is unknown.
-- Keep IDs paired with ratings in bounded reads, avoiding unqualified bulk/whose-rating behavior.
on discoverVariantIDs(docRef, collectionName, selectedOnly)
    set d to my checkedDocument(docRef)
    tell application "/Applications/Capture One.app"
        if collectionName is not missing value and collectionName is not "" then
            set scope to collection collectionName of d
        else
            set scope to d
        end if
        if selectedOnly then
            set sourceVariants to (every variant of scope whose selected is true)
        else
            set sourceVariants to every variant of scope
        end if
        set resultIDs to {}
        repeat with v in sourceVariants
            set end of resultIDs to (id of v as text)
        end repeat
        return resultIDs
    end tell
end discoverVariantIDs

-- Inventory without a collection lists the current collection; a named collection
-- resolves its own members without becoming current.
on variantScope(d, collectionName)
    tell application "/Applications/Capture One.app"
        if collectionName is missing value or collectionName is "" then return d
        return collection collectionName of d
    end tell
end variantScope

on readVariantRatings(docRef, variantIDs, collectionName)
    set d to my checkedDocument(docRef)
    tell application "/Applications/Capture One.app"
        set scope to my variantScope(d, collectionName)
        set results to {}
        repeat with requestedID in variantIDs
            set v to variant id (requestedID as text) of scope
            -- A read failure is not an unrated image. Fail rather than silently omit a match.
            set end of results to {variantId:(id of v as text), starRating:(rating of v as integer)}
        end repeat
        return results
    end tell
end readVariantRatings

-- isSelected comes from the scope's own selection filter, the one the selected filter
-- uses; the selected property of a variant can report another collection's selection.
on readVariantSummaries(docRef, variantIDs, collectionName)
    set d to my checkedDocument(docRef)
    tell application "/Applications/Capture One.app"
        set scope to my variantScope(d, collectionName)
        set selectedIDs to {}
        repeat with selectedID in (get id of (every variant of scope whose selected is true))
            set end of selectedIDs to selectedID as text
        end repeat
        set results to {}
        repeat with requestedID in variantIDs
            set v to variant id (requestedID as text) of scope
            set vId to (id of v as text)
            set vName to (name of v as text)
            set vSel to selectedIDs contains vId
            set vRating to (rating of v as integer)
            set vTag to 0
            try
                set vTag to (color tag of v as integer)
            end try
            set rawP to ""
            try
                set rawP to POSIX path of (path of parent image of v as text)
            end try
            set end of results to {variantId:vId, variantName:vName, parentImagePath:rawP, isSelected:vSel, starRating:vRating, colorTagVal:vTag}
        end repeat
        return results
    end tell
end readVariantSummaries

on cloneVariant(docRef, sourceId)
    tell application "/Applications/Capture One.app"
        set c to clone variant (my documentVariant(docRef, sourceId))
        -- Capture One can return a collection-scoped reference before its ID
        -- becomes readable. Retry only that exact reference's read, never clone.
        repeat with attempt from 1 to 20
            try
                set createdId to (id of c as text)
                return {cloneId:createdId}
            on error errorMessage number errorNumber
                if (errorNumber is not -1700 and errorNumber is not -1728) or attempt is 20 then
                    error errorMessage number errorNumber
                end if
            end try
            delay 0.1
            my checkedDocument(docRef)
        end repeat
    end tell
end cloneVariant

on deleteVariant(docRef, variantId, expectedPath, sourceId)
    set d to my checkedDocument(docRef)
    set routes to my variantRoutes(docRef, d)
    set v to my requiredVariant(routes, variantId)
    my assertParent(v, expectedPath)
    if sourceId is variantId then error "Cannot delete the source variant." number -27003
    set sourceVariant to my foundVariant(routes, sourceId)
    if sourceVariant is missing value then error "Source variant is absent; refusing deletion." number -27003
    my assertParent(sourceVariant, expectedPath)
    tell application "/Applications/Capture One.app"
        if (count of variants of parent image of v) < 2 then error "Cannot delete the last variant of an image." number -27003
        delete v
        -- Ask the image: a delete that only removed the variant from an album leaves it there.
        set existsAfter to false
        repeat with siblingID in (get id of every variant of parent image of sourceVariant)
            if (siblingID as text) is variantId then set existsAfter to true
        end repeat
        return {deleted:(not existsAfter), existsNow:existsAfter}
    end tell
end deleteVariant

on getAdjustmentsBatch(docRef, variantIds, collectionName)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docRef)
        set scoped to collectionName is not missing value and collectionName is not ""
        set scope to my variantScope(d, collectionName)
        if not scoped then set routes to my variantRoutes(docRef, d)
        set results to {}
        repeat with vid in variantIds
            if scoped then
                set v to variant id (vid as text) of scope
            else
                set v to my requiredVariant(routes, vid as text)
            end if
            set adj to adjustments of v
            
            set expVal to (exposure of adj as real)
            set contVal to (contrast of adj as real)
            set satVal to (saturation of adj as real)
            set tempVal to (temperature of adj as real)
            set tintVal to (tint of adj as real)
            
            set cVal to missing value
            set lVal to missing value
            set iVal to missing value
            set sVal to missing value
            set wVal to missing value
            set dtVal to missing value
            
            try
                set img to parent image of v
                try
                    set cVal to (EXIF camera model of img as text)
                end try
                try
                    set iVal to (EXIF ISO of img as text)
                end try
                try
                    set sVal to (EXIF shutter speed of img as text)
                end try
                try
                    set wVal to (EXIF white balance of img as text)
                end try
                try
                    set dtVal to ((EXIF capture date of img as «class isot») as text)
                end try
            end try
            
            try
                set lVal to (lens profile of lens correction of v as text)
            end try
            
            set rVal to (rating of v as integer)
            set tagVal to (color tag of v as integer)
            
            set parentPath to POSIX path of (path of parent image of v as text)
            set geo to missing value
            set geoError to missing value
            try
                set geo to my geometryRecordOf(v)
            on error errText
                set geoError to errText
            end try
            set end of results to {geometryRecord:geo, geometryUnavailableReason:geoError, parentImagePath:parentPath, variantId:(vid as text), exposureVal:expVal, contrastVal:contVal, saturationVal:satVal, temperatureVal:tempVal, tintVal:tintVal, cameraVal:cVal, lensVal:lVal, isoVal:iVal, shutterSpeedVal:sVal, asShotWBVal:wVal, captureDateVal:dtVal, starRating:rVal, colorTagVal:tagVal}
        end repeat
        return results
    end tell
end getAdjustmentsBatch

on applyAdjustments(docRef, variantId, expVal, contVal, satVal, tempVal, tintVal, expectedValues, expectedPath)
    tell application "/Applications/Capture One.app"
        set v to my documentVariant(docRef, variantId)
        set adj to adjustments of v
        
        -- Read before state
        set beforeExp to (exposure of adj as real)
        set beforeCont to (contrast of adj as real)
        set beforeSat to (saturation of adj as real)
        set beforeTemp to (temperature of adj as real)
        set beforeTint to (tint of adj as real)
        
        my assertParent(v, expectedPath)
        set actualValues to {beforeExp, beforeCont, beforeSat, beforeTemp, beforeTint}
        set tolerances to {0.00001, 0.00001, 0.00001, 0.01, 0.0001}
        repeat with n from 1 to 5
            set deltaValue to (item n of actualValues) - (item n of expectedValues)
            if deltaValue > (item n of tolerances) or deltaValue < (0 - (item n of tolerances)) then error "State changed immediately before write." number -27002
        end repeat
        -- Apply in verified order
        if expVal is not missing value then
            set exposure of adj to (expVal as real)
        end if
        if contVal is not missing value then
            set contrast of adj to (contVal as real)
        end if
        if satVal is not missing value then
            set saturation of adj to (satVal as real)
        end if
        if tempVal is not missing value then
            set temperature of adj to (tempVal as real)
        end if
        if tintVal is not missing value then
            set tint of adj to (tintVal as real)
        end if
        
        -- Read after state
        set afterExp to (exposure of adj as real)
        set afterCont to (contrast of adj as real)
        set afterSat to (saturation of adj as real)
        set afterTemp to (temperature of adj as real)
        set afterTint to (tint of adj as real)
        
        return {variantId:(variantId as text), beforeExposureVal:beforeExp, beforeContrastVal:beforeCont, beforeSaturationVal:beforeSat, beforeTemperatureVal:beforeTemp, beforeTintVal:beforeTint, afterExposureVal:afterExp, afterContrastVal:afterCont, afterSaturationVal:afterSat, afterTemperatureVal:afterTemp, afterTintVal:afterTint}
    end tell
end applyAdjustments

on ensurePreviewRecipe(docRef, recipeName, outputFolder, longEdge)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docRef)
        -- Catalog processing validates its default output even with a custom recipe.
        -- Preserve a usable default; initialize only a missing/unavailable location.
        if kind of d is catalog then
            try
                set defaultOutput to (output of d) as alias
            on error
                set output of d to POSIX file outputFolder
                set defaultOutput to (output of d) as alias
            end try
        end if
        if exists recipe recipeName of d then
            set r to recipe recipeName of d
        else
            set r to make new recipe at d with properties {name:recipeName}
        end if
        set output format of r to JPEG
        set JPEG quality of r to 80
        set export crop method of r to respect
        if export crop method of r is not respect then error "Preview recipe must respect crop."
        set color profile of r to "sRGB Color Space Profile"
        set scaling method of r to Long_Edge
        set scaling unit of r to pixels
        set primary scaling value of r to (longEdge as integer)
        set root folder location of r to POSIX file outputFolder
        set root folder type of r to custom location
        set output sub folder of r to ""
        set output name format of r to "preview"
        set enabled of r to false
        return {configured:true, recipeName:recipeName}
    end tell
end ensurePreviewRecipe

on processPreview(docRef, variantId, recipeName, outputFolder, outputSubFolder, outputName)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docRef)
        set r to recipe recipeName of d
        set root folder location of r to POSIX file outputFolder
        set root folder type of r to custom location
        set output sub folder of r to outputSubFolder
        set output name format of r to outputName
        
        set jobId to process (my requiredVariant(my variantRoutes(docRef, d), variantId as text)) recipe recipeName
        return {jobId:(jobId as text)}
    end tell
end processPreview

on createBaselineVariant(docRef, sourceId)
    tell application "/Applications/Capture One.app"
        set srcVar to my documentVariant(docRef, sourceId)
        set img to parent image of srcVar
        set beforeIds to {}
        repeat with itemV in (every variant of img)
            set end of beforeIds to (id of itemV as text)
        end repeat
        
        tell img to add variant
        
        set afterVariants to (every variant of img)
        set newVar to missing value
        repeat with cand in afterVariants
            set candId to (id of cand as text)
            if candId is not in beforeIds then
                set newVar to cand
                exit repeat
            end if
        end repeat
        
        if newVar is missing value then
            error "Failed to locate newly created baseline variant."
        end if
        
        return {baselineId:(id of newVar as text)}
    end tell
end createBaselineVariant



on geometryRecordOf(v)
    tell application "/Applications/Capture One.app"
        set a to adjustments of v
        set lc to lens correction of v
        set ratioText to crop aspect ratio of v
        if ratioText is missing value then set ratioText to ""
        set maxRect to maximum crop v apply false
        return {cropValues:crop of v, rotationDegrees:rotation of a, orientationDegrees:orientation of a, sourceDimensions:dimensions of parent image of v, maximumValues:maxRect, flipName:flip of a as text, ratioName:ratioText, keystoneValues:{keystone amount of a, keystone vertical of a, keystone horizontal of a, keystone skew of a, keystone aspect of a}, lensValues:{distortion of lc, focal length of lc, tilt of lc, tilt direction of lc, shift of lc, shift direction of lc, shift x of lc, shift y of lc}, profileName:lens profile of lc, hiddenAreas:hide distorted areas of lc, outsideAllowed:crop outside image of v}
    end tell
end geometryRecordOf

-- Source-file dimensions are read with ImageIO by the core. The native image
-- dimensions change with the first variant, so they are not a geometry precondition.
on geometrySnapshot(v)
    set g to my geometryRecordOf(v)
    return {cropValues of g, rotationDegrees of g, orientationDegrees of g, flipName of g, ratioName of g, keystoneValues of g, lensValues of g, profileName of g, hiddenAreas of g, outsideAllowed of g}
end geometrySnapshot

on checkedGeometryVariant(docRef, variantId, expectedPath, expectedGeometry, expectedTone)
    tell application "/Applications/Capture One.app"
        set v to my documentVariant(docRef, variantId)
        my assertParent(v, expectedPath)
        if my geometrySnapshot(v) is not equal to expectedGeometry then error "Geometry changed before dispatch." number -27002
        set a to adjustments of v
        set actualTone to {exposure of a as real, contrast of a as real, saturation of a as real, temperature of a as real, tint of a as real}
        set tolerances to {0.00001, 0.00001, 0.00001, 0.01, 0.0001}
        repeat with n from 1 to 5
            set deltaValue to (item n of actualTone) - (item n of expectedTone)
            if deltaValue > (item n of tolerances) or deltaValue < (0 - (item n of tolerances)) then error "Adjustments changed before geometry dispatch." number -27002
        end repeat
        return v
    end tell
end checkedGeometryVariant

-- Values are resolved against the checked snapshot; untouched controls are never reset.
-- Set amount last because native correction setters can affect its value.
on applyKeystone(v, targetKeystone)
    tell application "/Applications/Capture One.app"
        set a to adjustments of v
        if keystone vertical of a is not equal to item 2 of targetKeystone then set keystone vertical of a to item 2 of targetKeystone
        if keystone horizontal of a is not equal to item 3 of targetKeystone then set keystone horizontal of a to item 3 of targetKeystone
        if keystone skew of a is not equal to item 4 of targetKeystone then set keystone skew of a to item 4 of targetKeystone
        if keystone aspect of a is not equal to item 5 of targetKeystone then set keystone aspect of a to item 5 of targetKeystone
        if keystone amount of a is not equal to item 1 of targetKeystone then set keystone amount of a to (item 1 of targetKeystone as integer)
    end tell
end applyKeystone

-- Orientation first: crop coordinates are in the oriented canvas, and Capture One turns
-- the stored crop with the canvas.
on applyGeometry(docRef, variantId, expectedPath, expectedGeometry, expectedTone, targetCrop, targetRotation, targetKeystone, targetOrientation)
    set v to my checkedGeometryVariant(docRef, variantId, expectedPath, expectedGeometry, expectedTone)
    tell application "/Applications/Capture One.app"
        set a to adjustments of v
        if orientation of a is not equal to targetOrientation then set orientation of a to targetOrientation
        my applyKeystone(v, targetKeystone)
        if rotation of a is not equal to targetRotation then set rotation of a to targetRotation
        -- Rotation can recenter/shrink the native crop. Apply the final crop afterward.
        set crop of v to targetCrop
        return my geometryRecordOf(v)
    end tell
end applyGeometry

-- Lens and perspective corrections change the canvas. Do not extrapolate from RAW dimensions or
-- reuse bounds from another rotation or orientation. Uncorrected rotation- and orientation-only
-- changes also come here to keep Capture One's transformed crop. The caller journals the request before
-- entering this handler; any error after dispatch keeps the write block.
on applyCorrectedGeometry(docRef, variantId, expectedPath, expectedGeometry, expectedTone, requestedCrop, targetRotation, requestedRatio, targetKeystone, targetOrientation)
    set v to my checkedGeometryVariant(docRef, variantId, expectedPath, expectedGeometry, expectedTone)
    tell application "/Applications/Capture One.app"
        set a to adjustments of v
        if orientation of a is not equal to targetOrientation then set orientation of a to targetOrientation
        my applyKeystone(v, targetKeystone)
        if rotation of a is not equal to targetRotation then set rotation of a to targetRotation
        set nativeBounds to maximum crop v apply false
        set {boundsX, boundsY, boundsW, boundsH} to nativeBounds
        if boundsW <= 0 or boundsH <= 0 then error "Corrected geometry bounds are unavailable."
        if requestedCrop is not missing value then
            set targetCrop to requestedCrop
        else if requestedRatio is not missing value then
            set targetWidth to boundsW
            if boundsH * requestedRatio < targetWidth then set targetWidth to boundsH * requestedRatio
            set targetWidth to round targetWidth rounding down
            set targetHeight to round (targetWidth / requestedRatio) rounding down
            set targetCrop to {round boundsX, round boundsY, targetWidth, targetHeight}
        else
            -- Transform-only requests preserve Capture One's own recentered/shrunk crop.
            set targetCrop to crop of v
        end if
        set {cx, cy, cw, ch} to targetCrop
        if cw < 1 or ch < 1 then error "Corrected geometry crop is empty."
        -- Native transform-only crops can exceed the reported maximum rectangle.
        -- Keep that observed crop; containment applies to caller-selected crops.
        if requestedCrop is not missing value or requestedRatio is not missing value then
            if cx - cw / 2 < boundsX - boundsW / 2 - 2 or cx + cw / 2 > boundsX + boundsW / 2 + 2 or cy - ch / 2 < boundsY - boundsH / 2 - 2 or cy + ch / 2 > boundsY + boundsH / 2 + 2 then error "Requested crop exceeds native bounds after orientation or rotation; inspect operation status before any further write."
            set crop of v to targetCrop
        end if
        return {targetCropValues:targetCrop, boundsValues:nativeBounds, fittedCropValues:crop of v}
    end tell
end applyCorrectedGeometry

-- Classification writes are a patch and compare both values immediately before dispatch.
on applyMetadata(docRef, variantId, ratingValue, tagValue, expectedRating, expectedTag, expectedPath)
    tell application "/Applications/Capture One.app"
        set v to my documentVariant(docRef, variantId)
        my assertParent(v, expectedPath)
        if (rating of v as integer) is not expectedRating or (color tag of v as integer) is not expectedTag then error "Metadata changed immediately before write." number -27002
        if ratingValue is not missing value then set rating of v to (ratingValue as integer)
        if tagValue is not missing value then set color tag of v to (tagValue as integer)
        return {variantId:(id of v as text), ratingVal:(rating of v as integer), colorTagVal:(color tag of v as integer)}
    end tell
end applyMetadata

-- Resolve only explicitly requested IDs. Only Capture One's no-such-object reply
-- (-1728) classifies an ID as missing or out of scope; every other error propagates.
-- The caller fails the whole request when any ID is not present.
on readVariantSubset(docRef, collectionName, selectedOnly, variantIDs)
    set d to my checkedDocument(docRef)
    tell application "/Applications/Capture One.app"
        set scoped to collectionName is not missing value and collectionName is not ""
        set scope to my variantScope(d, collectionName)
        set selectedIDs to {}
        if selectedOnly then
            repeat with selectedID in (get id of (every variant of scope whose selected is true))
                set end of selectedIDs to selectedID as text
            end repeat
        end if
        set results to {}
        repeat with requestedID in variantIDs
            set idText to requestedID as text
            set isPresent to true
            -- An explicit get is required: coercing an unresolved reference reports -1700, not -1728.
            try
                set foundID to (get id of variant id idText of scope) as text
            on error errorMessage number errorNumber
                if errorNumber is not -1728 then error errorMessage number errorNumber
                set isPresent to false
            end try
            if isPresent then
                set v to variant id foundID of scope
                set selectedValue to true
                if selectedOnly then set selectedValue to selectedIDs contains foundID
                set end of results to {variantId:foundID, presence:"present", starRating:(rating of v as integer), parentImagePath:(POSIX path of (path of parent image of v as text)), inSelection:selectedValue}
            else
                set presence to "missing"
                if my foundVariant(my variantRoutes(docRef, d), idText) is not missing value then set presence to "out-of-scope"
                set end of results to {variantId:idText, presence:presence, starRating:0, parentImagePath:"", inSelection:false}
            end if
        end repeat
        return results
    end tell
end readVariantSubset

-- Known-ID lookup without enumerating the document. Only an ID that no route
-- holds reports absence; every error propagates so callers cannot mistake a
-- failed lookup for an absent variant.
on lookupVariantIdentities(docRef, variantIDs)
    set d to my checkedDocument(docRef)
    set routes to my variantRoutes(docRef, d)
    tell application "/Applications/Capture One.app"
        set results to {}
        repeat with requestedID in variantIDs
            set v to my foundVariant(routes, requestedID as text)
            if v is not missing value then
                set parentPath to POSIX path of (path of parent image of v as text)
                set end of results to {variantId:(id of v as text), isPresent:true, parentImagePath:parentPath}
            else
                set end of results to {variantId:(requestedID as text), isPresent:false, parentImagePath:""}
            end if
        end repeat
        return results
    end tell
end lookupVariantIdentities

-- Every variant ID of one known variant's parent image, without enumerating
-- the document. The anchor's parent must still be the expected image.
on readParentSiblings(docRef, anchorID, expectedPath)
    set v to my documentVariant(docRef, anchorID)
    tell application "/Applications/Capture One.app"
        my assertParent(v, expectedPath)
        -- One bulk property read; per-variant reads cost an Apple Event each.
        set rawIDs to id of every variant of (parent image of v)
        set siblingIDs to {}
        repeat with siblingID in rawIDs
            set end of siblingIDs to (siblingID as text)
        end repeat
        return siblingIDs
    end tell
end readParentSiblings
