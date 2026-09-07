tell application "/Applications/Capture One.app"
    set beforeDocs to {name, id} of every document
    open POSIX file "/private/tmp/c1-m0-1685-A/c1-m0-1685-A.cosessiondb"
    set d to document "c1-m0-1685-A.cosessiondb"
    set current collection of d to collection "Capture" of d
    return {beforeDocuments:beforeDocs, afterDocuments:{name, id} of every document, documentId:id of d, variantIds:id of every variant of d, variantStates:{exposure, contrast, temperature, tint} of adjustments of every variant of d, layers:{name, opacity} of every layer of variant id "1" of d, sourcePath:path of parent image of variant id "1" of d}
end tell
