reaper.Undo_BeginBlock()

cursorPos = reaper.GetCursorPosition()

item = reaper.GetSelectedMediaItem(0, 0)
if item ~= nil then
  track = reaper.GetMediaItem_Track(item)
 
  reaper.Main_OnCommand(40418, 0) --Item navigation: Select and move to item in previous track

  reaper.SetMediaItemInfo_Value(item, "B_UISEL", 1)
  reaper.SetTrackSelected(track, true)
end
 

reaper.SetEditCurPos(cursorPos, true, false ) --move view, seek play

reaper.Undo_EndBlock("Item navigation: up", 0)
