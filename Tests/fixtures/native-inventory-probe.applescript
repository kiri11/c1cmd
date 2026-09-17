on nativeInventoryIDs(docName, collectionName, selectedOnly, exactRating, minimumRating)
    tell application "/Applications/Capture One.app"
        if (count of documents) is not 1 then error "Expected one disposable document."
        set d to first document
        if (id of d as text) is not docName then error "Document changed."
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
end nativeInventoryIDs
