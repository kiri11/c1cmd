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

on listVariantsReference(docName, collectionName, selectedOnly)
    set d to my checkedDocument(docName)
    tell application "/Applications/Capture One.app"
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
end listVariantsReference
