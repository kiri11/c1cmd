tell application "/Applications/Capture One.app"
    set d to document "c1-m0-1685-A.cosessiondb"
    if id of d is not "/private/tmp/c1-m0-1685-A" then error "Fixture mismatch"
    set v to variant id "1" of d
    set sharpening amount of adjustments of v to 173
    set amount of curve point 1 of rgb curve of adjustments of v to 5
    set c to clone variant v
    return {newId:id of c, sourceSharp:sharpening amount of adjustments of v, cloneSharp:sharpening amount of adjustments of c, sourceCurve:{brightness, amount} of every curve point of rgb curve of adjustments of v, cloneCurve:{brightness, amount} of every curve point of rgb curve of adjustments of c, sourceLayers:{name, opacity} of every layer of v, cloneLayers:{name, opacity} of every layer of c}
end tell
