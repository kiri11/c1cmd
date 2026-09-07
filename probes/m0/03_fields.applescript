tell application "/Applications/Capture One.app"
set d to document "c1-m0-1685-A.cosessiondb"
if id of d is not "/private/tmp/c1-m0-1685-A" then error "Fixture mismatch"
set v to variant id "2" of d
set sourceV to variant id "1" of d
set siblingV to variant id "3" of d
set results to {}
set oldEditAll to edit all selected variants
select d variants {sourceV, v, siblingV}
try
set edit all selected variants to false
set beforeValue to exposure of adjustments of v
set sourceBefore to exposure of adjustments of sourceV
set siblingBefore to exposure of adjustments of siblingV
set exposure of adjustments of v to 1.234
set afterSet to exposure of adjustments of v
set exposure of adjustments of v to (afterSet + 0.2)
set afterAdd to exposure of adjustments of v
set exposure of adjustments of v to beforeValue
set end of results to {fieldName:"exposure", editAll:false, requested:1.234, actualSet:afterSet, actualAdd:afterAdd, restored:(exposure of adjustments of v), originalUnchanged:((exposure of adjustments of sourceV) is sourceBefore), siblingUnchanged:((exposure of adjustments of siblingV) is siblingBefore)}
set beforeValue to contrast of adjustments of v
set sourceBefore to contrast of adjustments of sourceV
set siblingBefore to contrast of adjustments of siblingV
set contrast of adjustments of v to 23.4
set afterSet to contrast of adjustments of v
set contrast of adjustments of v to (afterSet + 2)
set afterAdd to contrast of adjustments of v
set contrast of adjustments of v to beforeValue
set end of results to {fieldName:"contrast", editAll:false, requested:23.4, actualSet:afterSet, actualAdd:afterAdd, restored:(contrast of adjustments of v), originalUnchanged:((contrast of adjustments of sourceV) is sourceBefore), siblingUnchanged:((contrast of adjustments of siblingV) is siblingBefore)}
set beforeValue to saturation of adjustments of v
set sourceBefore to saturation of adjustments of sourceV
set siblingBefore to saturation of adjustments of siblingV
set saturation of adjustments of v to -12.3
set afterSet to saturation of adjustments of v
set saturation of adjustments of v to (afterSet + 3)
set afterAdd to saturation of adjustments of v
set saturation of adjustments of v to beforeValue
set end of results to {fieldName:"saturation", editAll:false, requested:-12.3, actualSet:afterSet, actualAdd:afterAdd, restored:(saturation of adjustments of v), originalUnchanged:((saturation of adjustments of sourceV) is sourceBefore), siblingUnchanged:((saturation of adjustments of siblingV) is siblingBefore)}
set beforeValue to temperature of adjustments of v
set sourceBefore to temperature of adjustments of sourceV
set siblingBefore to temperature of adjustments of siblingV
set temperature of adjustments of v to 5432
set afterSet to temperature of adjustments of v
set temperature of adjustments of v to (afterSet + 150)
set afterAdd to temperature of adjustments of v
set temperature of adjustments of v to beforeValue
set end of results to {fieldName:"temperature", editAll:false, requested:5432, actualSet:afterSet, actualAdd:afterAdd, restored:(temperature of adjustments of v), originalUnchanged:((temperature of adjustments of sourceV) is sourceBefore), siblingUnchanged:((temperature of adjustments of siblingV) is siblingBefore)}
set beforeValue to tint of adjustments of v
set sourceBefore to tint of adjustments of sourceV
set siblingBefore to tint of adjustments of siblingV
set tint of adjustments of v to 3.27
set afterSet to tint of adjustments of v
set tint of adjustments of v to (afterSet + 1.1)
set afterAdd to tint of adjustments of v
set tint of adjustments of v to beforeValue
set end of results to {fieldName:"tint", editAll:false, requested:3.27, actualSet:afterSet, actualAdd:afterAdd, restored:(tint of adjustments of v), originalUnchanged:((tint of adjustments of sourceV) is sourceBefore), siblingUnchanged:((tint of adjustments of siblingV) is siblingBefore)}
set edit all selected variants to true
set beforeValue to exposure of adjustments of v
set sourceBefore to exposure of adjustments of sourceV
set siblingBefore to exposure of adjustments of siblingV
set exposure of adjustments of v to 1.234
set afterSet to exposure of adjustments of v
set exposure of adjustments of v to (afterSet + 0.2)
set afterAdd to exposure of adjustments of v
set exposure of adjustments of v to beforeValue
set end of results to {fieldName:"exposure", editAll:true, requested:1.234, actualSet:afterSet, actualAdd:afterAdd, restored:(exposure of adjustments of v), originalUnchanged:((exposure of adjustments of sourceV) is sourceBefore), siblingUnchanged:((exposure of adjustments of siblingV) is siblingBefore)}
set beforeValue to contrast of adjustments of v
set sourceBefore to contrast of adjustments of sourceV
set siblingBefore to contrast of adjustments of siblingV
set contrast of adjustments of v to 23.4
set afterSet to contrast of adjustments of v
set contrast of adjustments of v to (afterSet + 2)
set afterAdd to contrast of adjustments of v
set contrast of adjustments of v to beforeValue
set end of results to {fieldName:"contrast", editAll:true, requested:23.4, actualSet:afterSet, actualAdd:afterAdd, restored:(contrast of adjustments of v), originalUnchanged:((contrast of adjustments of sourceV) is sourceBefore), siblingUnchanged:((contrast of adjustments of siblingV) is siblingBefore)}
set beforeValue to saturation of adjustments of v
set sourceBefore to saturation of adjustments of sourceV
set siblingBefore to saturation of adjustments of siblingV
set saturation of adjustments of v to -12.3
set afterSet to saturation of adjustments of v
set saturation of adjustments of v to (afterSet + 3)
set afterAdd to saturation of adjustments of v
set saturation of adjustments of v to beforeValue
set end of results to {fieldName:"saturation", editAll:true, requested:-12.3, actualSet:afterSet, actualAdd:afterAdd, restored:(saturation of adjustments of v), originalUnchanged:((saturation of adjustments of sourceV) is sourceBefore), siblingUnchanged:((saturation of adjustments of siblingV) is siblingBefore)}
set beforeValue to temperature of adjustments of v
set sourceBefore to temperature of adjustments of sourceV
set siblingBefore to temperature of adjustments of siblingV
set temperature of adjustments of v to 5432
set afterSet to temperature of adjustments of v
set temperature of adjustments of v to (afterSet + 150)
set afterAdd to temperature of adjustments of v
set temperature of adjustments of v to beforeValue
set end of results to {fieldName:"temperature", editAll:true, requested:5432, actualSet:afterSet, actualAdd:afterAdd, restored:(temperature of adjustments of v), originalUnchanged:((temperature of adjustments of sourceV) is sourceBefore), siblingUnchanged:((temperature of adjustments of siblingV) is siblingBefore)}
set beforeValue to tint of adjustments of v
set sourceBefore to tint of adjustments of sourceV
set siblingBefore to tint of adjustments of siblingV
set tint of adjustments of v to 3.27
set afterSet to tint of adjustments of v
set tint of adjustments of v to (afterSet + 1.1)
set afterAdd to tint of adjustments of v
set tint of adjustments of v to beforeValue
set end of results to {fieldName:"tint", editAll:true, requested:3.27, actualSet:afterSet, actualAdd:afterAdd, restored:(tint of adjustments of v), originalUnchanged:((tint of adjustments of sourceV) is sourceBefore), siblingUnchanged:((tint of adjustments of siblingV) is siblingBefore)}
on error errText number errNum
if edit all selected variants is false then set edit all selected variants to oldEditAll
error errText number errNum
end try
if edit all selected variants is true then set edit all selected variants to oldEditAll
return results
end tell
