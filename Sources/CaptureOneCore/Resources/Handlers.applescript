-- Handlers.applescript: Central AppleScript handlers for Capture One 16.8.5.30
-- Returns user-defined records exclusively with non-reserved key names.

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
            return {appVersion:appVer, hasDocument:false, docName:missing value, docPath:missing value, docId:missing value, isSession:false}
        end if
        set dName to ""
        try
            set dName to (name of d as text)
        end try
        set dId to ""
        try
            set dId to (id of d as text)
        end try
        set dPath to ""
        try
            set p to path of d
            set dPath to (POSIX path of (p as text))
        on error
            set dPath to dId
        end try
        if dId ends with ".cocatalog" then
            set dPath to dId
        else if dId ends with ".cosessiondb" then
            set dPath to dId
        end if
        
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

        return {appVersion:appVer, hasDocument:true, docName:dName, docPath:dPath, docId:dId, isSession:isSess}
    end tell
end getAppAndDocInfo

on listVariants(collectionName, selectedOnly)
    tell application "/Applications/Capture One.app"
        set d to missing value
        try
            set d to current document
        end try
        if d is missing value then
            try
                set d to first document
            end try
        end if
        set varList to {}
        set sourceVariants to {}
        if d is missing value then
            return {}
        end if
        
        if collectionName is not missing value and collectionName is not "" then
            set col to collection collectionName of d
            if selectedOnly then
                set sourceVariants to (every variant of col whose selected is true)
            else
                set sourceVariants to every variant of col
            end if
        else
            if selectedOnly then
                set sourceVariants to (every variant of d whose selected is true)
            else
                set sourceVariants to every variant of d
            end if
        end if
        
        repeat with v in sourceVariants
            set vId to (id of v as text)
            set vName to (name of v as text)
            set vSel to (selected of v as boolean)
            set vRating to 0
            try
                set vRating to (rating of v as integer)
            end try
            set vTag to 0
            try
                set vTag to (color tag of v as integer)
            end try
            set rawP to ""
            try
                set img to parent image of v
                set rawP to (POSIX path of (path of img as text))
            end try
            
            set end of varList to {variantId:vId, variantName:vName, parentImagePath:rawP, isSelected:vSel, starRating:vRating, colorTagVal:vTag}
        end repeat
        
        return varList
    end tell
end listVariants

on cloneVariant(docName, sourceId)
    tell application "/Applications/Capture One.app"
        set d to document docName
        set c to clone variant (variant id sourceId of d)
        return {cloneId:(id of c as text)}
    end tell
end cloneVariant

on deleteVariant(docName, variantId)
    tell application "/Applications/Capture One.app"
        set d to document docName
        delete variant id variantId of d
        set existsAfter to (exists variant id variantId of d)
        return {deleted:true, existsNow:existsAfter}
    end tell
end deleteVariant

on getAdjustmentsBatch(docName, variantIds)
    tell application "/Applications/Capture One.app"
        set d to document docName
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
            
            set end of results to {variantId:(vid as text), exposureVal:expVal, contrastVal:contVal, saturationVal:satVal, temperatureVal:tempVal, tintVal:tintVal, cameraVal:cVal, lensVal:lVal, isoVal:iVal, shutterSpeedVal:sVal, asShotWBVal:wVal, captureDateVal:dtVal, starRating:rVal, colorTagVal:tagVal}
        end repeat
        return results
    end tell
end getAdjustmentsBatch

on applyAdjustments(docName, variantId, expVal, contVal, satVal, tempVal, tintVal)
    tell application "/Applications/Capture One.app"
        set d to document docName
        set v to variant id (variantId as text) of d
        set adj to adjustments of v
        
        -- Read before state
        set beforeExp to (exposure of adj as real)
        set beforeCont to (contrast of adj as real)
        set beforeSat to (saturation of adj as real)
        set beforeTemp to (temperature of adj as real)
        set beforeTint to (tint of adj as real)
        
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
        set d to document docName
        if exists recipe recipeName of d then
            set r to recipe recipeName of d
        else
            set r to make new recipe at d with properties {name:recipeName}
        end if
        set output format of r to JPEG
        set JPEG quality of r to 80
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
        set d to document docName
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
        set d to document docName
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

on resetVariantAdjustments(docName, variantId)
    tell application "/Applications/Capture One.app"
        set d to document docName
        set v to variant id (variantId as text) of d
        reset adjustments v
        set adj to adjustments of v
        set expVal to (exposure of adj as real)
        set contVal to (contrast of adj as real)
        set satVal to (saturation of adj as real)
        set tempVal to (temperature of adj as real)
        set tintVal to (tint of adj as real)
        return {variantId:(variantId as text), afterExposureVal:expVal, afterContrastVal:contVal, afterSaturationVal:satVal, afterTemperatureVal:tempVal, afterTintVal:tintVal}
    end tell
end resetVariantAdjustments

