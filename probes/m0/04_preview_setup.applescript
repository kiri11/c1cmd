tell application "/Applications/Capture One.app"
    set d to document "c1-m0-1685-A.cosessiondb"
    if id of d is not "/private/tmp/c1-m0-1685-A" then error "Fixture mismatch"
    if exists recipe "c1-m0-1685-preview" of d then
        set r to recipe "c1-m0-1685-preview" of d
    else
        set r to make new recipe at d with properties {name:"c1-m0-1685-preview"}
    end if
    set output format of r to JPEG
    set JPEG quality of r to 80
    set color profile of r to "sRGB IEC61966-2.1"
    set scaling method of r to Long_Edge
    set scaling unit of r to pixels
    set primary scaling value of r to 1500
    set root folder type of r to custom location
    set root folder location of r to POSIX file "/private/tmp/c1-m0-1685-A/Output"
    set output sub folder of r to "job-001"
    set output name format of r to "clone-2"
    set enabled of r to false
    return {name, enabled, output format, color profile, scaling method, primary scaling value, root folder location, output sub folder, output name format} of r
end tell
