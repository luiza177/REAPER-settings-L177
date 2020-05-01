reaper.Undo_BeginBlock()
local timeStart, timeEnd = reaper.GetSet_LoopTimeRange(false, false, 0,0,false)


if timeStart == timeEnd then
  --local selection = reaper.NamedCommandLookup('_XENAKIOS_SELITEMSUNDEDCURSELTX')
  --reaper.Main_OnCommand(selection,0) --Xenakios/SWS: Select items under edit cursor on selected tracks
  reaper.Main_OnCommand(40759,0) --Item: Split items at edit cursor (select right)
else
  local split = reaper.NamedCommandLookup('_S&M_SPLIT2')
  reaper.Main_OnCommand(split,0)
end

reaper.Undo_EndBlock('Split like Pro Tools', 0)

--? works with groups?

