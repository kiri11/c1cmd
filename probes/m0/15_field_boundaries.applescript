tell application "/Applications/Capture One.app"
set d to document "c1-m0-1685-A.cosessiondb"
if id of d is not "/private/tmp/c1-m0-1685-A" then error "Fixture mismatch"
set v to variant id "2" of d
set baseline to {exposure, contrast, saturation, temperature, tint} of adjustments of v
set results to {}
try
set exposure of adjustments of v to -4
set end of results to {fieldName:"exposure", requested:-4, readback:exposure of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"exposure", requested:-4, errorCode:errNum, errorText:errText}
end try
try
set exposure of adjustments of v to 4
set end of results to {fieldName:"exposure", requested:4, readback:exposure of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"exposure", requested:4, errorCode:errNum, errorText:errText}
end try
try
set exposure of adjustments of v to 4.5
set end of results to {fieldName:"exposure", requested:4.5, readback:exposure of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"exposure", requested:4.5, errorCode:errNum, errorText:errText}
end try
try
set contrast of adjustments of v to -50
set end of results to {fieldName:"contrast", requested:-50, readback:contrast of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"contrast", requested:-50, errorCode:errNum, errorText:errText}
end try
try
set contrast of adjustments of v to 50
set end of results to {fieldName:"contrast", requested:50, readback:contrast of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"contrast", requested:50, errorCode:errNum, errorText:errText}
end try
try
set contrast of adjustments of v to 101
set end of results to {fieldName:"contrast", requested:101, readback:contrast of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"contrast", requested:101, errorCode:errNum, errorText:errText}
end try
try
set saturation of adjustments of v to -100
set end of results to {fieldName:"saturation", requested:-100, readback:saturation of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"saturation", requested:-100, errorCode:errNum, errorText:errText}
end try
try
set saturation of adjustments of v to 100
set end of results to {fieldName:"saturation", requested:100, readback:saturation of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"saturation", requested:100, errorCode:errNum, errorText:errText}
end try
try
set saturation of adjustments of v to 110
set end of results to {fieldName:"saturation", requested:110, readback:saturation of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"saturation", requested:110, errorCode:errNum, errorText:errText}
end try
try
set temperature of adjustments of v to 800
set end of results to {fieldName:"temperature", requested:800, readback:temperature of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"temperature", requested:800, errorCode:errNum, errorText:errText}
end try
try
set temperature of adjustments of v to 14000
set end of results to {fieldName:"temperature", requested:14000, readback:temperature of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"temperature", requested:14000, errorCode:errNum, errorText:errText}
end try
try
set temperature of adjustments of v to 15000
set end of results to {fieldName:"temperature", requested:15000, readback:temperature of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"temperature", requested:15000, errorCode:errNum, errorText:errText}
end try
try
set tint of adjustments of v to -50
set end of results to {fieldName:"tint", requested:-50, readback:tint of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"tint", requested:-50, errorCode:errNum, errorText:errText}
end try
try
set tint of adjustments of v to 50
set end of results to {fieldName:"tint", requested:50, readback:tint of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"tint", requested:50, errorCode:errNum, errorText:errText}
end try
try
set tint of adjustments of v to 55
set end of results to {fieldName:"tint", requested:55, readback:tint of adjustments of v}
on error errText number errNum
set end of results to {fieldName:"tint", requested:55, errorCode:errNum, errorText:errText}
end try
set exposure of adjustments of v to item 1 of baseline
set contrast of adjustments of v to item 2 of baseline
set saturation of adjustments of v to item 3 of baseline
set temperature of adjustments of v to item 4 of baseline
set tint of adjustments of v to item 5 of baseline
return {resultsVal:results, restoredVal:{exposure, contrast, saturation, temperature, tint} of adjustments of v}
end tell
