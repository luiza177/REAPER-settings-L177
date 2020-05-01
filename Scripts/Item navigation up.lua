reaper.Undo_BeginBlock()

cursorPos = reaper.GetCursorPosition()
reaper.Main_OnCommand(40418, 0) --Item navigation: Select and move to item in previous track
reaper.SetEditCurPos(cursorPos, true, false ) --move view, seek play

reaper.Undo_EndBlock("Item navigation: up", 0)
