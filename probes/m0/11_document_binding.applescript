tell application "/Applications/Capture One.app"
    set a to document "c1-m0-1685-A.cosessiondb"
    set b to document "c1-m0-1685-B.cosessiondb"
    return {currentDoc:id of current document, aDoc:id of a, bDoc:id of b, aVariant:variant id "1" of a, bVariant:variant id "1" of b, aPath:path of parent image of variant id "1" of a, bPath:path of parent image of variant id "1" of b, aExposure:exposure of adjustments of variant id "1" of a, bExposure:exposure of adjustments of variant id "1" of b, aRecipe:{root folder type, root folder location, output sub folder} of recipe "c1-m0-1685-preview" of a, bRecipes:name of every recipe of b, aHistory:path of every output event of variant id "1" of a, bHistory:path of every output event of variant id "1" of b, aCrop:crop of (variants 1 thru 2 of a), bCrop:crop of (variants 1 thru 2 of b)}
end tell
