tell application "/Applications/Capture One.app"
    set d to document "c1-m0-1685-A.cosessiondb"
    if id of d is not "/private/tmp/c1-m0-1685-A" then error "Fixture binding mismatch"
    set v to variant 1 of d
    if path of parent image of v is not "/tmp/c1-m0-1685-A/Capture/fixture.CR3" then error "Unexpected source"
    set exposure of adjustments of v to 0.25
    set contrast of adjustments of v to 7
    set saturation of adjustments of v to -8
    set l to make new layer at v with properties {name:"M0 preservation", kind:adjustment}
    fill mask l
    set exposure of adjustments of l to 0.75
    set opacity of l to 63
    set c to clone variant v
    set sibling to clone variant v
    return {sourceId:id of v, cloneId:id of c, siblingId:id of sibling, sourceState:{exposure, contrast, saturation} of adjustments of v, cloneState:{exposure, contrast, saturation} of adjustments of c, sourceLayers:{name, kind, opacity} of every layer of v, cloneLayers:{name, kind, opacity} of every layer of c, sourceLayerExposure:exposure of adjustments of every layer of v, cloneLayerExposure:exposure of adjustments of every layer of c}
end tell
