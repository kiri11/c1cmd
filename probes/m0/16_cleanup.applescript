tell application "/Applications/Capture One.app"
    if processing done script is not missing value then error "Callback changed; inspect before cleanup"
    if exists document "c1-m0-1685-A.cosessiondb" then
        set d to document "c1-m0-1685-A.cosessiondb"
        if id of d is not "/private/tmp/c1-m0-1685-A" then error "Fixture mismatch"
        if (count of jobs of d) is not 0 then error "Pending jobs; reconcile first"
        if exists recipe "c1-m0-1685-preview" of d then delete recipe "c1-m0-1685-preview" of d
        close d
    end if
    if exists document "c1-m0-1685-B.cosessiondb" then
        set d to document "c1-m0-1685-B.cosessiondb"
        if id of d is not "/private/tmp/c1-m0-1685-B" then error "Fixture mismatch"
        if (count of jobs of d) is not 0 then error "Pending jobs; reconcile first"
        close d
    end if
    set current document to document "Capture One Catalog"
    return {remainingDocs:name of every document, currentDoc:name of current document, processingCallback:processing done script, batchCallback:batch done script, editAll:edit all selected variants, remainingTestRecipe:exists recipe "c1-m0-1685-preview" of current document}
end tell
