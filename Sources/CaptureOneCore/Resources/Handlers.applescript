-- Handlers.applescript: Central AppleScript handlers for Capture One 16.8.5.30
-- Returns user-defined records exclusively with non-reserved key names.

on checkedDocument(expectedId)
    tell application "/Applications/Capture One.app"
        if (count of documents) is not 1 then error "Exactly one open document is required." number -27001
        set d to first document
        if (id of d as text) is not expectedId then error "Active document changed before dispatch." number -27001
        return d
    end tell
end checkedDocument

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

-- Qualified by the independent legacy enumeration for Session document, collection,
-- and selected scopes on 16.8.5.30. Every ID stays paired with its own summary.
on discoverFilteredVariantIDs(docName, collectionName, selectedOnly, exactRating, minimumRating)
    set d to my checkedDocument(docName)
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
on discoverVariantIDs(docName, collectionName, selectedOnly)
    set d to my checkedDocument(docName)
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

on readVariantRatings(docName, variantIDs)
    set d to my checkedDocument(docName)
    tell application "/Applications/Capture One.app"
        set results to {}
        repeat with requestedID in variantIDs
            set v to variant id (requestedID as text) of d
            -- A read failure is not an unrated image. Fail rather than silently omit a match.
            set end of results to {variantId:(id of v as text), starRating:(rating of v as integer)}
        end repeat
        return results
    end tell
end readVariantRatings

on readVariantSummaries(docName, variantIDs)
    set d to my checkedDocument(docName)
    tell application "/Applications/Capture One.app"
        set results to {}
        repeat with requestedID in variantIDs
            set v to variant id (requestedID as text) of d
            set vId to (id of v as text)
            set vName to (name of v as text)
            set vSel to (selected of v as boolean)
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

on cloneVariant(docName, sourceId)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docName)
        set c to clone variant (variant id sourceId of d)
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
            set d to my checkedDocument(docName)
        end repeat
    end tell
end cloneVariant

on deleteVariant(docName, variantId, expectedPath, sourceId)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docName)
        my assertParent(variant id variantId of d, expectedPath)
        if sourceId is variantId then error "Cannot delete the source variant." number -27003
        if not (exists variant id sourceId of d) then error "Source variant is absent; refusing deletion." number -27003
        my assertParent(variant id sourceId of d, expectedPath)
        if (count of variants of parent image of variant id variantId of d) < 2 then error "Cannot delete the last variant of an image." number -27003
        delete variant id variantId of d
        set existsAfter to (exists variant id variantId of d)
        return {deleted:(not existsAfter), existsNow:existsAfter}
    end tell
end deleteVariant

on getAdjustmentsBatch(docName, variantIds)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docName)
        set results to {}
        repeat with vid in variantIds
            set v to variant id (vid as text) of d
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
            
            set rVal to 0
            try
                set rVal to (rating of v as integer)
            end try
            set tagVal to 0
            try
                set tagVal to (color tag of v as integer)
            end try
            
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

on applyAdjustments(docName, variantId, expVal, contVal, satVal, tempVal, tintVal, expectedValues, expectedPath)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docName)
        set v to variant id (variantId as text) of d
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

on ensurePreviewRecipe(docName, recipeName, outputFolder)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docName)
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
        set primary scaling value of r to 1500
        set root folder location of r to POSIX file outputFolder
        set root folder type of r to custom location
        set output sub folder of r to ""
        set output name format of r to "preview"
        set enabled of r to false
        return {configured:true, recipeName:recipeName}
    end tell
end ensurePreviewRecipe

on processPreview(docName, variantId, recipeName, outputFolder, outputSubFolder, outputName)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docName)
        set r to recipe recipeName of d
        set root folder location of r to POSIX file outputFolder
        set root folder type of r to custom location
        set output sub folder of r to outputSubFolder
        set output name format of r to outputName
        
        set jobId to process (variant id (variantId as text) of d) recipe recipeName
        return {jobId:(jobId as text)}
    end tell
end processPreview

on createBaselineVariant(docName, sourceId)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docName)
        set srcVar to (variant id (sourceId as text) of d)
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

on applyGeometry(docName, variantId, expectedPath, expectedGeometry, expectedTone, targetCrop, targetRotation)
    tell application "/Applications/Capture One.app"
        set d to my checkedDocument(docName)
        set v to variant id (variantId as text) of d
        my assertParent(v, expectedPath)
        if my geometrySnapshot(v) is not equal to expectedGeometry then error "Geometry changed before dispatch." number -27002
        set a to adjustments of v
        set actualTone to {exposure of a as real, contrast of a as real, saturation of a as real, temperature of a as real, tint of a as real}
        set tolerances to {0.00001, 0.00001, 0.00001, 0.01, 0.0001}
        repeat with n from 1 to 5
            set deltaValue to (item n of actualTone) - (item n of expectedTone)
            if deltaValue > (item n of tolerances) or deltaValue < (0 - (item n of tolerances)) then error "Adjustments changed before geometry dispatch." number -27002
        end repeat
        if rotation of a is not equal to targetRotation then set rotation of a to targetRotation
        -- Rotation can recenter/shrink the native crop. Apply the final crop afterward.
        set crop of v to targetCrop
        return my geometryRecordOf(v)
    end tell
end applyGeometry
