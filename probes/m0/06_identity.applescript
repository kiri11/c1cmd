tell application "/Applications/Capture One.app"
    set d to document "c1-m0-1685-A.cosessiondb"
    set originalDocId to id of d
    set originalIds to id of every variant of d
    set c to clone variant (variant id "1" of d)
    set disposableId to id of c
    set immediatelyReadable to exposure of adjustments of variant id disposableId of d
    delete variant id disposableId of d
    set afterDeleteIds to id of every variant of d
    set deletedExists to exists variant id disposableId of d
    set current collection of d to collection "All Images" of d
    set sorting order of current collection of d to by name
    set sorting reversed of current collection of d to true
    set reorderedIds to id of every variant of d
    close d
    set closedExists to exists document id originalDocId
    open POSIX file "/private/tmp/c1-m0-1685-A/c1-m0-1685-A.cosessiondb"
    set reopened to document "c1-m0-1685-A.cosessiondb"
    set current collection of reopened to collection "Capture" of reopened
    return {beforeDocId:originalDocId, afterDocId:id of reopened, beforeIds:originalIds, temporaryId:disposableId, immediateValue:immediatelyReadable, afterDelete:afterDeleteIds, deletedStillExists:deletedExists, reordered:reorderedIds, documentExistsWhileClosed:closedExists, reopenedIds:id of every variant of reopened, staleSpecifierResolves:exists d}
end tell
