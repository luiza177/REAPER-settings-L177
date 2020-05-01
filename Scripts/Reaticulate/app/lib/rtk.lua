
-- Copyright 2017-2019 Jason Tackaberry
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.


-- RTK - Reaper Toolkit
--
-- A modest UI library for Reaper, inspired by gtk+.
--
local log = require 'lib.log'
class = require 'lib.middleclass'

-------------------------------------------------------------------------------------------------------------
-- Misc utility functions
function clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

function table.merge(dst, src)
    for k, v in pairs(src) do
        dst[k] = v
    end
    return dst
end

function hex2rgb(s)
    local r = tonumber(s:sub(2, 3), 16) or 0
    local g = tonumber(s:sub(4, 5), 16) or 0
    local b = tonumber(s:sub(6, 7), 16) or 0
    local a = tonumber(s:sub(8, 9), 16)
    return r / 255, g / 255, b / 255, a ~= nil and a / 255 or 1.0
end

function rgb2hex(r, g, b)
    return string.format('#%02x%02x%02x', r, g, b)
end

function hex2int(s)
    local r, g, b = hex2rgb(s)
    return (r * 255) + ((g * 255) << 8) + ((b * 255) << 16)
end

function int2hex(d)
    return rgb2hex(d & 0xff, (d >> 8) & 0xff, (d >> 16) & 0xff)
end

function color2rgba(s)
    local r, g, b, a
    if type(s) == 'table' then
        return table.unpack(s)
    else
        return hex2rgb(s)
    end
end

function color2luma(s)
    local r, g, b, a = color2rgba(s)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

local function point_in_box(x, y, bx, by, bw, bh)
    return x >= bx and y >= by and x <= bx + bw and y <= by + bh
end

-------------------------------------------------------------------------------------------------------------

local rtk = {
    has_js_reascript_api = reaper.JS_Window_GetFocus ~= nil,

    scale = 1,
    x = 0,
    y = 0,
    w = gfx.w,
    h = gfx.h,

    -- Frame rate (measured in rtk.update)
    fps = 30,

    -- Last observed dock state for the window
    dockstate = nil,
    -- true if the mouse is positioned within the UI window
    in_window = false,
    -- true if the UI window currently has keyboard focus.  This requires the js_ReaScriptAPI
    -- extension and if it's not installed will always be true.
    is_focused = true,
    -- the hwnd of the currently focused window (per js_ReaScriptAPI)
    focused_hwnd = nil,
    -- The top-level widget for the app (normally a container of some sort).
    widget = nil,
    -- The currently focused widget (or nil if no widget is focused)
    focused = nil,
    -- All widgets under the mouse for the last mousedown event.  Used by the main loop to
    -- query widgets for draggability when the mouse is dragged.  This is nil when the
    -- mouse button isn't pressed
    drag_candidates = nil,
    -- The currently dragging widget (or nil if none)
    dragging = nil,
    -- true if the currently dragging widget is eligible to be dropped and false
    -- otherwise.  When false, it means ondrop*() handlers will never be called.
    -- This should be set to false by the widget's ondragstart() handler.  This
    -- is useful for drag-only widgets such scrollbars that want to leverage the
    -- global drag-handling logic without any need for droppability.
    --
    -- TODO: this is better signalled via an ondragstart() return value or possible
    -- via the event object.
    droppable = true,
    -- The current drop target of the currently dragging widget (or nil if
    -- not dragging or not currently over a valid top target)
    dropping = nil,
    -- The user argument as returned by ondragstart() for the currently dragging
    -- widget
    dragarg = nil,
    -- True will the app is running.  rtk.quit() will set this to false.
    running = true,
    -- hwnd of the gfx window (iff JS extension is installed)
    hwnd = nil,

    mouse = {
        BUTTON_LEFT = 1,
        BUTTON_MIDDLE = 64,
        BUTTON_RIGHT = 2,
        BUTTON_MASK = (1 | 2 | 64),
        x = 0,
        y = 0,
        cap = 0,
        wheel = 0,
        down = 0,
        cursor = 0,
        cursors = {
            undefined = 0,
            pointer = 32512,
            beam = 32513,
            loading = 32514,
            crosshair = 32515,
            up = 32516,
            hand = 32649,
            size_all = 32646,
            size_ns = 32645,
            size_ew = 32644,
            size_sw_ne = 32643,
            size_nw_se = 32642,
            pointer_loading = 32650,
            pointer_help = 32651
        },
    },

    theme = nil,
    themes = {
        dark = {
            dark = true,
            accent = '#47abff',
            accent_subtle = '#306088',
            window_bg = '#252525',
            text = '#ffffff',
            text_faded = '#bbbbbb',
            button = '#666666',
            buttontext = '#ffffff',
            entry_border_hover = '#3a508e',
            entry_border_focused = '#4960b8',
            entry_bg = '#5f5f5f7f',
            entry_label = '#ffffff8f',
            entry_selection_bg = '#0066bb',
            scrollbar = '#ffffff',
        },
        light = {
            light = true,
            accent = '#47abff',
            accent_subtle = '#a1d3fc',
            window_bg = '#dddddd',
            button = '#dededebb',
            buttontext = '#000000',
            text = '#000000',
            text_faded = '#555555',
            entry_border_hover = '#3a508e',
            entry_border_focused = '#4960b8',
            entry_bg = '#eeeeee7f',
            entry_label = '#0000007f',
            entry_selection_bg = '#9fcef4',
            scrollbar = '#000000',
        }
    },

    fonts = {
        BOLD = string.byte('b'),
        ITALICS = string.byte('i') << 8,
        UNDERLINE = string.byte('u') << 16,
        -- nil values will use default
        -- FIXME: do something sane for flags
        default = {'Calibri', 18},
        label = nil,
        button = nil,
        entry  = nil,
        heading = {'Calibri', 22, 98},

        -- Font size multiplier, adjusted by platform
        multiplier = 1.0
    },

    keycodes = {
        UP          = 30064,
        DOWN        = 1685026670,
        LEFT        = 1818584692,
        RIGHT       = 1919379572,
        RETURN      = 13,
        ENTER       = 13,
        SPACE       = 32,
        BACKSPACE   = 8,
        ESCAPE      = 27,
        TAB         = 9,
        HOME        = 1752132965,
        END         = 6647396,
        INSERT      = 6909555,
        DELETE      = 6579564,
    },

    -- Set in rtk.init()
    os = {
        mac = false,
        windows = false,
        linux = false
    },

    onupdate = function() end,
    onreflow = function() end,
    onmove = function() end,
    onresize = function() end,
    ondock = function() end,
    onclose = function() end,
    onkeypresspre = function(event) end,
    onkeypresspost = function(event) end,
    onmousewheel = function(event) end,

    _event = nil,
    _reflow_queued = false,
    -- Set of specific widgets that need to be reflowed on next update.  If
    -- _reflow_queued is true but this value is nil then the entire scene is
    -- reflowed.
    _reflow_widgets = nil,
    _draw_queued = false,
    -- After drawing, the window contents is blitted to this backing store as an
    -- optimization for subsequent UI updates where no event has occured.
    _backingstore = nil,
    -- The last unique id assigned to a widget object
    _last_widget_serial = 0,
    -- A stack of blit dest ids,
    _dest_stack = {},
    -- A map of currently processing animations keyed on widget id and attr
    -- name.  Each entry is a table in the form: {widget, attribute name,
    -- easingfn, srcval, dstval, pct, pctstep, do_reflow, donefn}
    _animations = {},
    _animations_len = 0,
    _easing_functions = {},
    _frame_count = 0,
    _frame_time = nil,
}

--
-- Animation functions
--
local function _easing_linear(srcval, dstval, pct)
    return srcval + (pct * (dstval - srcval))
end


local function _do_animations(now)
    -- Calculate frame rate (rtk.fps)
    if not rtk._frame_time then
        rtk._frame_time = now
        rtk._frame_count = 0
    else
        local duration = now - rtk._frame_time
        if duration > 2 then
            rtk.fps = rtk._frame_count / duration
            rtk._frame_time = now
            rtk._frame_count = 0
        end
    end
    rtk._frame_count = rtk._frame_count + 1

    -- Execute pending animations
    if rtk._animations_len > 0 then
        -- Queue tracking donefn for completed animations.  We don't want to
        -- invoke the callbacks within the loop in case the callback queues
        -- another animation.
        local donefuncs = nil
        for key, animation in pairs(rtk._animations) do
            local widget, attr, easingfn, srcval, dstval, pct, pctstep, do_reflow, donefn = table.unpack(animation)
            local pct = pct + pctstep
            local lim = dstval > srcval and math.min or math.max
            local newval = lim(dstval, easingfn(srcval, dstval, pct))
            widget[attr] = newval
            if newval == dstval then
                -- Animation is done.
                rtk._animations[key] = nil
                rtk._animations_len = rtk._animations_len - 1
                if donefn then
                    if not donefuncs then
                        donefuncs = {}
                    end
                    donefuncs[#donefuncs + 1] = {donefn, widget}
                end
                log.debug2('animation: done %s: %s -> %s on %s (%s)', attr, srcval, dstval, widget, widget.id)
            else
                animation[6] = pct
            end
            if do_reflow then
                rtk._reflow_queued = true
            end
        end
        if donefuncs then
            for _, cbinfo in ipairs(donefuncs) do
                cbinfo[1](cbinfo[2])
            end
        end
        -- True indicates animations were performed
        return true
    end
end


function rtk.push_dest(dest)
    rtk._dest_stack[#rtk._dest_stack + 1] = gfx.dest
    gfx.dest = dest
end

function rtk.pop_dest()
    gfx.dest = table.remove(rtk._dest_stack, #rtk._dest_stack)
end

function rtk.queue_reflow(widget)
    if widget then
        if rtk._reflow_widgets then
            rtk._reflow_widgets[widget] = true
        elseif not rtk._reflow_queued then
            rtk._reflow_widgets = {[widget]=true}
        end
    else
        rtk._reflow_widgets = nil
    end
    rtk._reflow_queued = true
end

function rtk.queue_draw()
    rtk._draw_queued = true
end

function rtk.set_mouse_cursor(cursor)
    if cursor and rtk.mouse.cursor == rtk.mouse.cursors.undefined then
        rtk.mouse.cursor = cursor
    end
end


function rtk.reflow(full)
    local widgets = rtk._reflow_widgets
    rtk._reflow_queued = false
    rtk._reflow_widgets = nil
    local t0 = os.clock()
    if full ~= true and widgets and rtk.widget.realized and #widgets < 20 then
        for widget, _ in pairs(widgets) do
            widget:reflow()
        end
    else
        rtk.widget:reflow(0, 0, rtk.w, rtk.h)
    end
    local reflow_time = os.clock() - t0
    if reflow_time > 0.05 then
        log.warn("rtk: slow reflow: %s", reflow_time)
    end
    rtk.onreflow()
end

local function _get_mouse_button_event(bit)
    local type = nil
    -- Determine whether the mouse button (at the given bit position) is either
    -- pressed or released.  We update the rtk.mouse.down bitmap to selectively
    -- toggle that single bit rather than just copying the entire mouse_cap bitmap
    -- in order to ensure that multiple simultaneous mouse up/down events will
    -- be emitted individually (in separate invocations of rtk.update()).
    if rtk.mouse.down & bit == 0 and gfx.mouse_cap & bit ~= 0 then
        rtk.mouse.down = rtk.mouse.down | bit
        type = rtk.Event.MOUSEDOWN
    elseif rtk.mouse.down & bit ~= 0 and gfx.mouse_cap & bit == 0 then
        rtk.mouse.down = rtk.mouse.down & ~bit
        type = rtk.Event.MOUSEUP
    end
    if type then
        local event = rtk._event:reset(type)
        event.x, event.y = gfx.mouse_x, gfx.mouse_y
        event:set_modifiers(gfx.mouse_cap, bit)
        return event
    end
end

local function _get_mousemove_event(generated)
    event = rtk._event:reset(rtk.Event.MOUSEMOVE)
    event.x, event.y = gfx.mouse_x, gfx.mouse_y
    event.generated = generated
    event:set_modifiers(gfx.mouse_cap, gfx.mouse_cap)
    return event
end


function rtk.update()
    gfx.update()
    local need_draw = rtk._draw_queued

    -- Check focus.  Ensure focused_hwnd is updated *before* calling onupdate()
    -- handler.
    if rtk.has_js_reascript_api then
        rtk.focused_hwnd = reaper.JS_Window_GetFocus()
        local focused = rtk.hwnd == rtk.focused_hwnd
        if focused ~= rtk.is_focused then
            rtk.is_focused = focused
            need_draw = true
        end
    end

    if rtk.onupdate() == false then
        return true
    end
    local now = os.clock()

    need_draw = _do_animations(now) or need_draw

    if gfx.w ~= rtk.w or gfx.h ~= rtk.h then
        rtk.w, rtk.h = gfx.w, gfx.h
        rtk.onresize()
        rtk.reflow(true)
        need_draw = true
    elseif rtk._reflow_queued then
        rtk.reflow()
        need_draw = true
    elseif rtk.w > 2048 or rtk.h > 2048 then
        -- Window dimensions exceed max image size so we can't use backing store.
        need_draw = true
    end

    local event = nil

    if gfx.mouse_wheel ~= 0 then
        event = rtk._event:reset(rtk.Event.MOUSEWHEEL)
        event:set_modifiers(gfx.mouse_cap, 0)
        event.wheel = -gfx.mouse_wheel
        rtk.onmousewheel(event)
        gfx.mouse_wheel = 0
    end

    if rtk.mouse.down ~= gfx.mouse_cap & rtk.mouse.BUTTON_MASK then
        -- Generate events for mouse button down/up.
        event = _get_mouse_button_event(1)
        if not event then
            event = _get_mouse_button_event(2)
            if not event then
                event = _get_mouse_button_event(64)
            end
        end
    end

    -- Generate key event
    local char = gfx.getchar()
    if char > 0 then
        event = rtk._event:reset(rtk.Event.KEY)
        event:set_modifiers(gfx.mouse_cap, 0)
        event.char = nil
        event.keycode = char
        if char <= 26 and event.ctrl then
            event.char = string.char(char + 96)
        elseif char >= 32 and char ~= 127 then
            if char <= 255 then
                event.char = string.char(char)
            elseif char <= 282 then
                event.char = string.char(char - 160)
            elseif char <= 346 then
                event.char = string.char(char - 224)
            end
        end
        rtk.onkeypresspre(event)
    elseif char < 0 then
        rtk.onclose()
    end

    local last_in_window = rtk.in_window
    rtk.in_window = gfx.mouse_x >= 0 and gfx.mouse_y >= 0 and gfx.mouse_x <= gfx.w and gfx.mouse_y <= gfx.h
    if not event then
        -- Generate mousemove event if the mouse actually moved, or simulate one if a
        -- draw has been queued.
        local mouse_moved = rtk.mouse.x ~= gfx.mouse_x or rtk.mouse.y ~= gfx.mouse_y
        -- Ensure we emit the event if draw is forced, or if we're moving within the window, or
        -- if we _were_ in the window but now suddenly aren't (to ensure mouseout cases are drawn)
        if need_draw or (mouse_moved and rtk.in_window) or last_in_window ~= rtk.in_window or
           -- Also generate mousemove events if we're currently dragging but the mouse isn't
           -- otherwise moving.  This allows dragging against the edge of a viewport to steadily
           -- scroll.
           (rtk.dragging and gfx.mouse_cap & rtk.mouse.BUTTON_MASK ~= 0) then
            event = _get_mousemove_event(not mouse_moved)
        end
    end

    if event then
        event.time = now
        -- rtk.mouse.down = gfx.mouse_cap & rtk.mouse.BUTTON_MASK
        rtk.mouse.x = gfx.mouse_x
        rtk.mouse.y = gfx.mouse_y

        -- Clear mouse cursor before drawing widgets to determine if any widget wants a custom cursor
        local last_cursor = rtk.mouse.cursor
        rtk.mouse.cursor = rtk.mouse.cursors.undefined

        if rtk.widget.visible == true then
            rtk.widget:_handle_event(0, 0, event, false)
            if event.type == rtk.Event.MOUSEUP then
                rtk.drag_candidates = nil
                if rtk.dropping then
                    rtk.dropping:ondropblur(event, rtk.dragging, rtk.dragarg)
                    rtk.dropping = nil
                end
                if rtk.dragging then
                    rtk.dragging:ondragend(event, rtk.dragarg)
                    rtk.dragging = nil
                    rtk.dragarg = nil
                end
            elseif rtk.drag_candidates and event.type == rtk.Event.MOUSEMOVE and
                   not event.generated and event.buttons ~= 0 and not rtk.dragarg then
                -- Mouse moved while button pressed, test now to see any of the drag
                -- candidates we registered from the precending MOUSEDOWN event want
                -- to start a drag.
                --
                -- Clear event handled flag to give ondragstart() handler the opportunity
                -- to reset it as handled to prevent further propogation.
                event.handled = nil
                -- Reset droppable status.
                rtk.droppable = true
                for n, widget in ipairs(rtk.drag_candidates) do
                    arg = widget:ondragstart(event)
                    if arg ~= false then
                        rtk.dragging = widget
                        rtk.dragarg = arg
                        break
                    elseif event.handled then
                        break
                    end
                end
                rtk.drag_candidates = nil
            end

            if rtk._reflow_queued then
                -- One of the event handlers has requested a reflow.  It'd happen on the next
                -- update() but we do it now before drawing just to avoid potential flickering.
                rtk.reflow()
                rtk._draw_queued = true
            end
            -- Now that we have reflowed (maybe), after a mouse up or mousewheel
            -- event, inject a mousemove event to cause any widgets under the
            -- mouse to draw the hover state.
            if event.type == rtk.Event.MOUSEUP or event.type == rtk.Event.MOUSEWHEEL then
                rtk.widget:_handle_event(0, 0, _get_mousemove_event(false), false)
            end
            -- If the event was marked as handled, or if one of the handlers explicitly requested a
            -- redraw (or a reflow in which case we implicitly redraw) then do so now.  Otherwise
            -- just repaint the current backing store.
            if need_draw or rtk._draw_queued or event.handled then
                rtk.clear()
                -- Clear _draw_queued flag before drawing so that if some event
                -- handler triggered from _draw() queues a redraw it won't get
                -- lost.
                rtk._draw_queued = false
                rtk.widget:_draw(0, 0, 0, 0, 0, 0, event)
                rtk._backingstore:resize(rtk.w, rtk.h, false)
                rtk._backingstore:drawfrom(-1)
            else
                rtk._backingstore:draw(nil, nil, nil, 6)
            end
        end

        -- If the current cursor is undefined, it means no widgets requested a custom cursor,
        -- so default to pointer.
        if rtk.mouse.cursor ~= last_cursor then
            if rtk.mouse.cursor == rtk.mouse.cursors.undefined then
                rtk.mouse.cursor = rtk.mouse.cursors.pointer
            end
            if type(rtk.mouse.cursor) == 'number' then
                gfx.setcursor(rtk.mouse.cursor)
            else
                -- Set cursor by cursor filename.
                -- http://reaper.fm/sdk/cursors/cursors.php#files
                gfx.setcursor(1, rtk.mouse.cursor)
            end
        end

        if not event.handled then
            if rtk.focused and event.type == rtk.Event.MOUSEDOWN then
                rtk.focused:blur()
                rtk.queue_draw()
            end
        end
        if event.type == rtk.Event.KEY then
            rtk.onkeypresspost(event)
        end
    else
        rtk._backingstore:draw(nil, nil, nil, 6)
    end
    local dockstate, x, y = gfx.dock(-1, true, true)
    if dockstate ~= rtk.dockstate then
        rtk._handle_dock_change(dockstate)
    end
    if x ~= rtk.x or y ~= rtk.y then
        local last_x, last_y = rtk.x, rtk.y
        rtk.x = x
        rtk.y = y
        rtk.onmove(last_x, last_y)
    end
end

function rtk.get_reaper_theme_bg()
    -- Default to COLOR_BTNHIGHLIGHT which corresponds to "Main window 3D
    -- highlight" theme element.
    local idx = 20
    if reaper.GetOS():starts('OSX') then
        -- Determined empirically on Mac to match the theme background.
        idx = 1
    end
    return int2hex(reaper.GSC_mainwnd(idx))
end


function rtk.set_theme(name, iconpath, overrides)
    rtk.theme = {}
    table.merge(rtk.theme, rtk.themes[name])
    if overrides then
        table.merge(rtk.theme, overrides)
    end
    rtk.theme.iconpath = iconpath
    gfx.clear = hex2int(rtk.theme.window_bg)
end

function rtk._handle_dock_change(dockstate)
    if rtk.has_js_reascript_api then
        rtk.hwnd = nil

        -- Find the gfx hwnd based on window title.  First use JS_Window_Find()
        -- which is pretty fast, and if it doesn't appear to be this gfx instance
        -- (based on screen coordinates) then we do the much more expensive call to
        -- JS_Window_ArrayFind().  If that only returns one result, then we go
        -- with our original hwnd, and if not, then we find the one that matches
        -- the screen position of this gfx.
        local x, y = gfx.clienttoscreen(0, 0)
        local function verify_hwnd_coords(hwnd)
            local _, hx, hy, _, _ = reaper.JS_Window_GetClientRect(hwnd)
            return hx == x and hy == y
        end

        rtk.hwnd = reaper.JS_Window_Find(rtk.title, true)
        if not verify_hwnd_coords(rtk.hwnd) then
            -- The returned hwnd doesn't match our screen coordinates so do
            -- a deeper search.
            local a = reaper.new_array({}, 10)
            local nmatches = reaper.JS_Window_ArrayFind(rtk.title, true, a)
            if nmatches > 1 then
                local hwnds = a.table()
                for n, hwndptr in ipairs(hwnds) do
                    local hwnd = reaper.JS_Window_HandleFromAddress(hwndptr)
                    if verify_hwnd_coords(hwnd) then
                        rtk.hwnd = hwnd
                        break
                    end
                end
            end
        end
    end
    rtk.queue_reflow()
    rtk.dockstate = dockstate
    rtk.ondock()
end

function rtk.init(title, w, h, dockstate, x, y)
    -- Detect platform
    local os = reaper.GetOS()
    if os:starts('Win') then
        rtk.os.windows = true
    elseif os:starts('OSX') then
        rtk.os.mac = true
        rtk.fonts.multiplier = 0.8
    elseif os:starts('Linux') then
        rtk.os.linux = true
        rtk.fonts.multiplier = 0.8
    end

    -- Register easing functions by name for rtk.Widget:animate()
    rtk._easing_functions['linear'] = _easing_linear

    -- Reusable event object.
    rtk._event = rtk.Event()
    rtk._backingstore = rtk.Image():create(w, h)
    rtk.title = title
    rtk.x, rtk.y = x or 0, y or 0
    rtk.w, rtk.h = w, h
    rtk.dockstate = dockstate
    if not rtk.widget then
        rtk.widget = rtk.Container()
    end
end


function rtk.clear()
    gfx.set(hex2rgb(rtk.theme.window_bg))
    gfx.rect(0, 0, rtk.w, rtk.h, 1)
end


function rtk.focus()
    if rtk.hwnd and rtk.has_js_reascript_api then
        reaper.JS_Window_SetFocus(rtk.hwnd)
        rtk.queue_draw()
        return true
    else
        return false
    end
end

local function _log_error(err)
    log.exception('rtk: %s', err)
end

local function _run()
    local status, err = xpcall(rtk.update, _log_error)
    if not status then
        error(err)
        return
    end
    if rtk.running then
        reaper.defer(_run)
    end
end

function rtk.run()
    gfx.init(rtk.title, rtk.w, rtk.h, rtk.dockstate, rtk.x, rtk.y)
    -- Update immediately to clear canvas with gfx.clear (defined by set_theme())
    -- to avoid ugly flicker.
    rtk.clear()
    gfx.update()

    local dockstate, _, _ = gfx.dock(-1, true, true)
    rtk._handle_dock_change(dockstate)

    _run()
end

function rtk.quit()
    rtk.running = false
end


function rtk.set_font(font, size, scale, flags)
    gfx.setfont(1, font, size * scale * rtk.scale * rtk.fonts.multiplier, flags or 0)
end


function rtk.layout_gfx_string(s, wrap, truncate, boxw, boxh, justify)
    local w, h = gfx.measurestr(s)
    -- Common case where the string fits in the box.  But first if the
    -- string contains a newline and we're center justifying then
    -- we need to take the slow path.
    if justify ~= rtk.Widget.CENTER or not s:find('\n') then
        if w <= boxw or (not wrap and not truncate) then
            return w, h, h, s
        end
    end
    -- Text exceeds bounding box.
    if not wrap and truncate then
        -- This isn't exactly the most efficient.
        local truncated = ''
        local lw = 0
        for i = 1, s:len() do
            local segment = s:sub(1, i)
            local segment_lw, _ = gfx.measurestr(segment)
            if segment_lw > boxw then
                break
            end
            lw = segment_lw
            truncated = segment
        end
        return lw, h, h, truncated
    end

    -- We'll need to wrap the string.  Do the expensive work.
    local startpos = 1
    local endpos = 1
    local wrappos = 1
    local len = s:len()
    local segments = {}
    local widths = {}
    local maxwidth = 0
    local function addsegment(segment)
        w, _ = gfx.measurestr(segment)
        segments[#segments+1] = segment
        widths[#widths+1] = w
        maxwidth = math.max(w, maxwidth)
    end
    for endpos = 1, len do
        local substr = s:sub(startpos, endpos)
        local ch = s:sub(endpos, endpos)
        local w, _ = gfx.measurestr(substr)
        if w > boxw or ch == '\n' then
            if wrappos == startpos then
                wrappos = endpos - 1
            end
            if wrappos > startpos then
                addsegment(string.strip(s:sub(startpos, wrappos)))
                startpos = wrappos + 1
                wrappos = endpos
            else
                addsegment('')
            end
        end
        if ch == ' ' or ch == '-' or ch == ',' or ch == '.' then
            wrappos = endpos
        end
    end
    if startpos ~= len then
        addsegment(string.strip(s:sub(startpos, len)))
    end
    -- This is a bit of a lame way to implement string justification, by
    -- prepending lines with spaces to get roughly close to the proper width.
    -- This naive approach won't work for right justification, and even for
    -- center justified text there is an error margin.  If that needs to be
    -- fixed, then we will have to return the unconcatenated segments with
    -- position data included, and implement a separate draw function to process
    -- them.  Meanwhile, this is good enough for now.
    if justify == rtk.Widget.CENTER then
        local spacew, _ = gfx.measurestr(' ')
        for n, line in ipairs(segments) do
            -- How much space we have to add to the line to get it centered
            -- relative to our widest line.
            local lpad = (maxwidth - widths[n]) / 2
            local nspaces = math.round(lpad / spacew)
            segments[n] = string.rep(' ', nspaces) .. line
        end
    end
    local wrapped = table.concat(segments, "\n")
    local ww, wh = gfx.measurestr(wrapped)
    return ww, wh, h, wrapped
end

-------------------------------------------------------------------------------------------------------------

rtk.Event = class('rtk.Event')
rtk.Event.static.MOUSEDOWN = 1
rtk.Event.static.MOUSEUP = 2
rtk.Event.static.MOUSEMOVE = 3
rtk.Event.static.MOUSEWHEEL = 4
rtk.Event.static.KEY = 5

function rtk.Event:initialize(type)
    self:reset(type)
end

function rtk.Event:reset(type)
    self.type = type
    -- Widget that handled this event
    self.handled = nil
    -- Widgets that the mouse is currently hovering over
    self.hovering = nil
    -- We don't reset offx and offy attributes, but they are only valid if
    -- hovering is not nil.
    self.button = 0
    self.buttons = 0
    self.wheel = 0
    return self
end

function rtk.Event:is_mouse_event()
    return self.type <= rtk.Event.MOUSEWHEEL
end

function rtk.Event:set_widget_hovering(widget, offx, offy)
    if self.hovering == nil then
        self.hovering = {}
    end
    self.hovering[widget.id] = 1
    self.offx = offx
    self.offy = offy
end

function rtk.Event:is_widget_hovering(widget)
    return self.hovering and self.hovering[widget.id] == 1 and widget.hovering
end

function rtk.Event:set_modifiers(cap, button)
    self.modifiers = cap & (4 | 8 | 16 | 32)
    self.ctrl = cap & 4 ~= 0
    self.shift = cap & 8 ~= 0
    self.alt = cap & 16 ~= 0
    self.meta = cap & 32 ~= 0
    self.buttons = cap & (1 | 2 | 64)
    self.button = button
end

function rtk.Event:set_handled(widget)
    self.handled = widget or true
    rtk.queue_draw()
    -- Return true so caller can return us directly from a handler, just as a convenient
    -- way to acknowledge an event.
    return true
end

-------------------------------------------------------------------------------------------------------------

rtk.Image = class('rtk.Image')
rtk.Image.static.last_index = -1

function rtk.Image.make_icon(name)
    return rtk.Image(rtk.theme.iconpath .. '/' .. name .. '.png')
end

function rtk.Image:initialize(src, sx, sy, sw, sh)
    self.sx = 0
    self.sy = 0
    self.width = -1
    self.height = -1

    if sh ~= nil then
        self:viewport(src, sx, sy, sw, sh)
    elseif src ~= nil then
        self:load(src)
    end
end

function rtk.Image:create(w, h)
    rtk.Image.static.last_index = rtk.Image.static.last_index + 1
    self.id = rtk.Image.static.last_index
    if h ~= nil then
        self:resize(w, h)
    end
    return self
end

function rtk.Image:clone()
    local newimg = rtk.Image():create(self.width, self.height)
    newimg:drawfrom(self.id, self.sx, self.sy, 0, 0, self.width, self.height)
    return newimg
end

function rtk.Image:resize(w, h, clear)
    if self.width ~= w or self.height ~= h then
        self.width, self.height = w, h
        gfx.setimgdim(self.id, w, h)
        if clear ~= false then
            self:clear()
        end
    end
    return self
end

function rtk.Image:clear(r, g, b, a)
    rtk.push_dest(self.id)
    gfx.r, gfx.g, gfx.b, gfx.a = r or 0, g or 0, b or 0, a or 0
    gfx.rect(0, 0, self.width, self.height, 1)
    rtk.pop_dest()
    return self
end

function rtk.Image:load(path)
    self.id = gfx.loadimg(rtk.Image.static.last_index + 1, path)
    if self.id ~= -1 then
        rtk.Image.static.last_index = self.id
        self.width, self.height = gfx.getimgdim(self.id)
    else
        self.width, self.height = -1, -1
    end
    return self
end

function rtk.Image:viewport(src, sx, sy, sw, sh)
    self.id = src.id
    self.sx = sx
    self.sy = sy
    self.width = sw == -1 and src.width or sw
    self.height = sh == -1 and src.height or sh
    return self
end

function rtk.Image:draw(dx, dy, scale, mode, a)
    gfx.mode = mode or 0
    gfx.a = a or 1.0
    gfx.blit(self.id, scale or 1.0, 0, self.sx, self.sy, self.width, self.height, dx or 0, dy or 0)
    gfx.mode = 0
    return self
end

function rtk.Image:drawregion(sx, sy, dx, dy, w, h, scale, mode, a)
    gfx.mode = mode or 6
    gfx.a = a or 1.0
    gfx.blit(self.id, scale or 1.0, 0, sx or self.sx, sy or self.sw, w or self.width, h or self.height, dx or 0, dy or 0)
    gfx.mode = 0
    return self
end

function rtk.Image:drawfrom(src, sx, sy, dx, dy, w, h, scale, mode, a)
    rtk.push_dest(self.id)
    gfx.mode = mode or 6
    gfx.a = a or 1.0
    gfx.blit(src, scale or 1.0, 0, sx or self.sx, sy or self.sy, w or self.width, h or self.height, dx or 0, dy or 0)
    gfx.mode = 0
    rtk.pop_dest()
end


function rtk.Image:filter(mr, mg, mb, ma, ar, ag, ab, aa)
    rtk.push_dest(self.id)
    gfx.muladdrect(0, 0, self.width, self.height, mr, mg, mb, ma, ar, ag, ab, aa)
    rtk.pop_dest()
    return self
end

function rtk.Image:accent(color)
    local r, g, b, a = hex2rgb(color or rtk.theme.accent)
    return self:filter(0, 0, 0, 1.0, r, g, b, 0)
end


-------------------------------------------------------------------------------------------------------------


rtk.Widget = class('Widget')

rtk.Widget.static.LEFT = 0
rtk.Widget.static.TOP = 0
rtk.Widget.static.CENTER = 1
rtk.Widget.static.RIGHT = 2
rtk.Widget.static.BOTTOM = 2

rtk.Widget.static.RELATIVE = 0
rtk.Widget.static.FIXED = 1

local function _filter_border(value)
    if type(value) == 'string' then
        return {value, nil, nil}
    else
        return value
    end
end
rtk.Widget.static._attr_filters = {
    halign = {left=rtk.Widget.LEFT, center=rtk.Widget.CENTER, right=rtk.Widget.RIGHT},
    valign = {top=rtk.Widget.TOP, center=rtk.Widget.CENTER, bottom=rtk.Widget.BOTTOM},
    position = {relative=rtk.Widget.RELATIVE, fixed=rtk.Widget.FIXED},
    border = _filter_border,
    tborder = _filter_border,
    rborder = _filter_border,
    bborder = _filter_border,
    lborder = _filter_border,
}

function rtk.Widget:initialize()
    self.id = rtk._last_widget_serial
    rtk._last_widget_serial = rtk._last_widget_serial + 1

    -- User defined coords
    self.x = 0
    self.y = 0
    self.w = nil
    self.h = nil

    -- Padding that subclasses *should* implement.
    --
    -- NOTE: this works like CSS's content-box box sizing model where padding is over
    -- and above content.  Consequently, a child may end up with a size larger than
    -- a parent container offers, due to added padding.
    --
    -- If this is undesirable, then instead of specifying the padding as part of the
    -- child's attributes, specify the padding as additional attributes to the
    -- container's add() method.
    self.lpadding = 0
    self.tpadding = 0
    self.rpadding = 0
    self.bpadding = 0

    self.halign = rtk.Widget.LEFT
    self.valign = rtk.Widget.TOP
    self.position = rtk.Widget.RELATIVE
    self.focusable = false
    self.alpha = 1.0
    -- Mouse cursor to display when mouse is hovering over widget
    self.cursor = nil
    -- If true, dragging widgets will cause parent viewports (if any) to display
    -- the scrollbar while the child is dragging
    self.show_scrollbar_on_drag = false

    -- Computed coordinates relative to widget parent container
    self.cx = nil
    self.cy = nil
    self.cw = nil
    self.ch = nil
    -- Box supplied from parent on last reflow
    self.box = nil

    -- Window x/y offsets that were supplied in last draw.  These coordinates
    -- indicate where the widget is drawn within the overall backing store, but
    -- may not be screen coordinates e.g. in the case of a viewport.
    self.last_offx = nil
    self.last_offy = nil
    -- Screen coordinates for this widget's backing store.  Generally the child
    -- doesn't need to know this, except in cases where the child needs to interact
    -- directly with the screen (e.g. to display a popup menu).  As with
    -- last_offx and last_offy, these are passed in through _draw().
    self.sx = nil
    self.sy = nil

    -- Time of last click time (for measuring double clicks)
    self.last_click_time = 0

    -- Indicates whether the widget should be rendered by its parent.
    self.visible = true
    -- A ghost widget is one that takes up space in terms of layout but is
    -- otherwise not drawn.
    self.ghost = false
    -- True if the widget is ready to be drawn (it is initialized and reflowed)
    self.realized = false
    -- The widget's ancestor viewport as of last reflow.  Can be nil if there
    -- is no containing viewport.
    self.viewport = nil
    -- Set to true if the mouse is hovering over the widget
    self.hovering = false


    self.debug_color = {math.random(), math.random(), math.random()}
end

function rtk.Widget:setattrs(attrs)
    if attrs ~= nil then
        for k, v in pairs(attrs) do
            self[k] = self:_filter_attr(k, v)
        end
    end
end

function rtk.Widget:draw_debug_box(offx, offy)
    if self.cw then
        gfx.set(self.debug_color[1], self.debug_color[2], self.debug_color[3], 0.2)
        gfx.rect(self.cx + offx, self.cy + offy, self.cw, self.ch, 1)
    end
end

function rtk.Widget:_unpack_border(border)
    local color, thickness, padding = table.unpack(border)
    self:setcolor(color or rtk.theme.button)
    return thickness or 1, padding or 0
end


function rtk.Widget:_draw_borders(offx, offy, all, t, r, b, l)
    if all then
        local thickness, offset = self:_unpack_border(all)
        -- TODO: support thickness
        gfx.rect(self.cx + offx - offset, self.cy + offy - offset, self.cw + offset, self.ch + offset, 0)
    end
    if t then
        local thickness, offset = self:_unpack_border(t)
        gfx.rect(self.cx + offx, self.cy + offy - offset, self.cw, thickness, 1)
    end
    if r then
        local thickness, offset = self:_unpack_border(r)
        gfx.rect(self.cx + offx + self.cw + offset, self.cy + offy - thickness, thickness, self.ch, 1)
    end
    if b then
        local thickness, offset = self:_unpack_border(b)
        gfx.rect(self.cx + offx, self.cy + offy + self.ch + offset - thickness, self.cw, thickness, 1)
    end
    if l then
        local thickness, offset = self:_unpack_border(l)
        gfx.rect(self.cx + offx - offset, self.cy + offy, thickness, self.ch, 1)
    end
end

function rtk.Widget:_hovering(offx, offy)
    local x, y = self.cx + offx, self.cy + offy
    return rtk.in_window and
           point_in_box(rtk.mouse.x, rtk.mouse.y, x, y, self.cw, self.ch)
end

local function resolve(coord, box, default)
    if coord and box then
        if coord < -1 then
            return box + coord
        elseif coord <= 1 then
            return math.abs(box * coord)
        end
    end
    return coord or default
end

function rtk.Widget:_resolvesize(boxw, boxh, w, h, defw, defh)
    return resolve(w, boxw, defw), resolve(h, boxh, defh)
end


function rtk.Widget:_resolvepos(boxx, boxy, x, y, defx, defy)
    return x + boxx, y + boxy
end

function rtk.Widget:_reflow(boxx, boxy, boxw, boxh, fillw, fillh, viewport)
    self.cx, self.cy = self:_resolvepos(boxx, boxy, self.x, self.y, boxx, boxy)
    self.cw, self.ch = self:_resolvesize(boxw, boxh, self.w, self.h, boxw, boxh)
end

-- Draws the widget.  Subclasses override.
--
-- px and py are the parent's position relative to the current drawing target.
--
-- offx and offy are the coordinates on the current drawing target that the
-- widget should offset its position from as requested by the parent container.
-- This may not necessarily be screen coordinates if for example the parent is
-- drawing the child to a backing store.  These values implicitly include px and
-- py (because they are relative to the drawing target, not the parent).
--
-- sx and sy are the screen coordinates of the current drawing target.
--
-- event is the rtk.Event object that occurred at the time of the redraw.
function rtk.Widget:_draw(px, py, offx, offy, sx, sy, event)
    self.last_offx, self.last_offy = offx, offy
    self.sx, self.sy = sx, sy
    self.px, self.py = px, py
    return false
end

-- Draws the widget background.  This isn't called by the default _draw() method
-- and is left up to subclasses to call explicitly at the appropriate time.
function rtk.Widget:_draw_bg(offx, offy, event)
    if self.bg and not self.ghost then
        self:setcolor(self.bg)
        gfx.rect(self.cx + offx, self.cy + offy, self.cw, self.ch, 1)
    end
end


-- Process an unhandled event.  It's the caller's responsibility not to
-- invoke this method on a handled event.  It's the implementation's
-- responsibility to determine if the widget _should_ handle this event,
-- and if so, to dispatch to the appropriate on* method and declare
-- the event handled by setting the handled attribute.
--
-- offx and offy refer to the widget's parent's position relative to screen
-- origin (top left).  This is different than the offset coordinates of
-- _draw() because these are always screen coordinates, regardless of whether
-- the widget is being rendered into a backing store (such as a viewport).
--
-- If clipped is true, it means the parent viewport has indicated that the
-- mouse is currently outside the viewport.  This can be used to filter mouse
-- events -- a clipped event must not trigger an onmouseenter() for example, but
-- it can be used to trigger onmouseleave().  (This is the reason that the parent
-- even bothers to call us.)
--
-- When an event is marked as handled, a redraw is automatically performed.
-- If the a redraw is required when an event isn't explicitly marked as
-- handled, such as in the case of a blur event, then rtk.queue_draw() must
-- be called.
--
-- The default widget implementation handles mouse events only
function rtk.Widget:_handle_event(offx, offy, event, clipped)
    if not clipped and self:_hovering(offx, offy) then
        event:set_widget_hovering(self, offx, offy)
        -- rtk.set_mouse_cursor(self.cursor)
        if event.type == rtk.Event.MOUSEMOVE then
            if rtk.dragging == self then
                self:ondragmousemove(event, rtk.dragarg)
            end
            if self.hovering == false then
                -- Mousemove event over a widget that's not currently marked as hovering.
                if event.buttons == 0 or self:focused() then
                    -- No mouse buttons pressed or the widget currently has focus.  We
                    -- set the widget as hovering and mark the event as handled if the
                    -- onmouseenter() handler returns true.
                    if not event.handled and self:onmouseenter(event) then
                        self.hovering = true
                        rtk.set_mouse_cursor(self.cursor)
                        self:onmousemove(event)
                        rtk.queue_draw()
                    end
                else
                    -- If here, mouse is moving while buttons are pressed.
                    if rtk.dragarg and not event.generated and rtk.droppable then
                        -- We are actively dragging a widget
                        if rtk.dropping == self or self:ondropfocus(event, rtk.dragging, rtk.dragarg) then
                            if rtk.dropping then
                                if rtk.dropping ~= self then
                                    rtk.dropping:ondropblur(event, rtk.dragging, rtk.dragarg)
                                elseif not event.generated then
                                    -- self is the drop target
                                    rtk.dropping:ondropmousemove(event, rtk.dragging, rtk.dragarg)
                                end
                            end
                            event:set_handled(self)
                            rtk.dropping = self
                        end
                    end
                end
            else
                if event.handled then
                    -- We were and technically still are hovering, but another widget has handled this
                    -- event.  One scenario is a a higher z-index container that's partially obstructing
                    -- our view and it has absorbing the event.
                    self:onmouseleave(event)
                    self.hovering = false
                else
                    rtk.set_mouse_cursor(self.cursor)
                    self:onmousemove(event)
                end
            end
        elseif event.type == rtk.Event.MOUSEDOWN then
            if not event.handled and self:onmousedown(event) then
                event:set_handled(self)
                rtk.set_mouse_cursor(self.cursor)
            end
            -- Register this widget as a drag candidate.  If the mouse moves with the button
            -- pressed, onupdate() will invoke ondragstart() for us.
            if not rtk.drag_candidates then
                rtk.drag_candidates = {self}
            else
                table.insert(rtk.drag_candidates, self)
            end
        elseif event.type == rtk.Event.MOUSEUP then
            if not event.handled then
                if self:onmouseup() then
                    event:set_handled(self)
                end
                if self:focused() then
                    rtk.set_mouse_cursor(self.cursor)
                    self:onclick(event)
                    if event.time - self.last_click_time <= 0.5 then
                        self:ondblclick(event)
                    end
                    self.last_click_time = event.time
                    event:set_handled(self)
                end
            end
            -- rtk.dragging and rtk.dropping are also nulled (as needed) in rtk.update()
            if rtk.dropping == self then
                self:ondropblur(event, rtk.dragging, rtk.dragarg)
                if self:ondrop(event, rtk.dragging, rtk.dragarg) then
                    event:set_handled(self)
                end
            end
            rtk.queue_draw()
        elseif event.type == rtk.Event.MOUSEWHEEL then
            if not event.handled and self:onmousewheel(event) then
                event:set_handled(self)
            end
        end


    -- Cases below are when mouse is not hovering over widget
    elseif event.type == rtk.Event.MOUSEMOVE then
        if rtk.dragging == self then
            self:ondragmousemove(event, rtk.dragarg)
        end
        if self.hovering == true then
            -- Be sure not to trigger mouseleave if we're dragging this widget
            if rtk.dragging ~= self then
                self:onmouseleave(event)
                rtk.queue_draw()
                self.hovering = false
            end
        elseif event.buttons ~= 0 and rtk.dropping then
            if rtk.dropping == self then
                -- Dragging extended outside the bounds of the last drop target (we know because
                -- (we're not hovering), so need to reset.
                rtk.dropping:ondropblur(event, rtk.dragging, rtk.dragarg)
                rtk.dropping = nil
            end
            rtk.queue_draw()
        end
    end
end

-- Sets an attribute on the widget to the given value.
--
-- If trigger is anything other than false, setting the attribute will cause
-- invocation of on*() handles (if applicable).  Setting to false will disable
-- this, which can be useful if setting the attribute in another on* handler to
-- prevent circular calls.
function rtk.Widget:attr(attr, value, trigger)
    value = self:_filter_attr(attr, value)
    if value ~= self[attr] then
        self[attr] = value
        self:onattr(attr, value, trigger == nil or trigger)
    end
    -- Return self to allow chaining multiple attributes
    return self
end

-- Subclasses can implement this to filter attribute values to ensure validity.
function rtk.Widget:_filter_attr(attr, value)
    local map = rtk.Widget._attr_filters[attr]
    local t = type(map)
    if t == 'table' then
        return map[value] or value
    elseif t == 'function' then
        return map(value) or value
    end
    return value
end


function rtk.Widget:setcolor(s, amul)
    local r, g, b, a = color2rgba(s)
    if amul then
        a = a * amul
    end
    gfx.set(r, g, b, a * self.alpha)
    return self
end

function rtk.Widget:move(x, y)
    self.x, self.y = x, y
    return self
end

function rtk.Widget:resize(w, h)
    self.w, self.h = w, h
    return self
end

function rtk.Widget:reflow(boxx, boxy, boxw, boxh, fillw, fillh, viewport)
    if not boxx then
        -- reflow() called with no arguments to indicate local reflow needed without
        -- any change to bounding box, so we can reuse the previous bounding box.
        if self.box then
            self:_reflow(table.unpack(self.box))
        else
            -- We haven't ever reflowed before, so no prior bounding box.   Caller isn't
            -- allowed to depend on our return arguments when called without supplying a
            -- bounding box.
            return
        end
    else
        self.viewport = viewport
        self.box = {boxx, boxy, boxw, boxh, fillw, fillh, viewport}
        self:_reflow(boxx, boxy, boxw, boxh, fillw, fillh, viewport)
    end
    self:onreflow()
    self.realized = true
    return self.cx, self.cy, self.cw, self.ch
end

-- Returns the widget's position relative to its viewport (or the root widget if there is
-- no viewport).
--
-- This is different than self.last_offy + self.cy because last_offy is only set if the
-- widget is drawn.  If the widget's parent container isn't visible (scrolled outside the
-- viewport say) then that approach doesn't work.  This function takes the more expensive
-- but reliable route of crawling up the widget hierarchy.  Consequently, this should not
-- be called frequently.
function rtk.Widget:_get_relative_pos_to_viewport()
    local x, y = 0, 0
    local widget = self
    while widget do
        x = x + widget.cx
        y = y + widget.cy
        if widget.viewport and widget.viewport == widget.parent then
            break
        end
        widget = widget.parent
    end
    return x, y
end

-- Ensures the widget is fully visible in the viewport, plus the additional
-- padding.  tpadding provides distance from top of viewport if scrolling
-- up, and bpadding applies below the widget if scrolling down.
function rtk.Widget:scrolltoview(tpadding, bpadding)
    if not self.visible or not self.box or not self.viewport then
        -- Not visible or not reflowed yet, or the widget has no viewport to scroll.
        return
    end
    local _, absy = self:_get_relative_pos_to_viewport()
    if absy - tpadding < self.viewport.vy then
        self.viewport:scrollto(0, absy - tpadding)
    elseif absy + self.ch + bpadding > self.viewport.vy + self.viewport.ch then
        local y = absy + self.ch + bpadding - self.viewport.ch
        self.viewport:scrollto(0, absy + self.ch + bpadding - self.viewport.ch)
    end
end

function rtk.Widget:hide()
    return self:attr('visible', false)
end

function rtk.Widget:show()
    return self:attr('visible', true)
end

function rtk.Widget:toggle()
    if self.visible == true then
        return self:hide()
    else
        return self:show()
    end
end

function rtk.Widget:focus()
    if self:onfocus() ~= false then
        if rtk.focused then
            rtk.focused:blur()
        end
        rtk.focused = self
        rtk.queue_draw()
    end
    return self
end

function rtk.Widget:blur()
    if self:focused() then
        if self:onblur() ~= false then
            rtk.focused = nil
            rtk.queue_draw()
        end
    end
    return self
end

function rtk.Widget:focused()
    return rtk.focused == self
end


function rtk.Widget:animate(attr, dstval, duration, props, donefn)
    local srcval = self[attr]
    assert(type(srcval) == 'number')

    local easingfn = rtk._easing_functions[props and props.easing or 'linear']
    assert(type(easingfn) == 'function')

    local key = string.format('%d.%s', self.id, attr)
    if not rtk._animations[key] then
        rtk._animations_len = rtk._animations_len + 1
    end

    local pctstep = 1.0 / (rtk.fps * duration)
    rtk._animations[key] = {
        self, attr, _easing_linear,
        srcval, dstval, 0, pctstep,
        (props and props.reflow) and true or false,
        donefn
    }
end

-- Called when an attribute is set via attr()
function rtk.Widget:onattr(attr, value, trigger)
    if attr == 'visible' then
        -- Toggling visibility, must reflow entire scene
        rtk.queue_reflow()
        if value == true then
            -- Set realized to false in case show() has been called from within a
            -- draw() handler for another widget earlier in the scene graph.  We
            -- need to make sure that this widget isn't drawn until it has a chance
            -- to reflow.
            self.realized = false
        end
    else
        rtk.queue_reflow(self)
    end
end

-- Called before any drawing from within the internal draw method.
function rtk.Widget:ondrawpre(offx, offy, event) end


-- Called after the widget is finished drawing from within the internal
-- draw method.  The callback may augment the widget's appearance by drawing
-- over top it.
function rtk.Widget:ondraw(offx, offy, event) end

-- Called when the mouse button is clicked over the widget.  The default
-- implementation focuses the widget if the focusable attribute is true.
--
-- Returning true indicates that the event is considered handled and the click
-- should not propagate to lower z-index widgets.
--
-- It is also necessary for this callback to return true for onclick() to fire.
function rtk.Widget:onmousedown(event)
    if self.focusable then
        self:focus()
        return self:focused()
    else
        return false
    end
end

-- Called when the mouse button is released over the widget, which may or
-- may not be a focused widget (or even focusable)
function rtk.Widget:onmouseup(event) end

-- Called when the mousewheel is moved while hovering.  The default
-- implementation does nothing.  Returning true indicates the event
-- is considered handled and parent viewport(s) should not process
-- the event.
function rtk.Widget:onmousewheel(event) end


-- Called when the mouse button is released over a focused widget.
function rtk.Widget:onclick(event) end

-- Called after two successive onclick events occur within 500ms.
function rtk.Widget:ondblclick(event) end

-- Called once when the mouse is moved to within the widget's bounding box.
-- Returning rtk.Event.STOP_PROPAGATION indicates that the widget is opaque
-- and should block lower z-index widgets from receiving the mousemove event.
-- Returning any non-nil value treats the widget as hovering.
--
-- If the mouse moves while the pointer stays within the widget's bounding box
-- this callback isn't reinvoked.
function rtk.Widget:onmouseenter(event)
    if self.focusable then
        return true
    end
end

-- Called once when the mouse was previously hovering over a widget but then moves
-- outside its bounding box.
function rtk.Widget:onmouseleave(event) end

function rtk.Widget:onmousemove(event) end


-- Called when a widget is about to be focused.  If it returns false,
-- the focus is rejected, otherwise, with any other value, the widget
-- is focused.
function rtk.Widget:onfocus(event) return true end

-- Called when a widget is about to lose focus.  If it returns false
-- then the widget retains focus.
function rtk.Widget:onblur(event) return true end


-- Called when a widget is dragged.  If the callback returns a non-false value
-- then the drag is allowed, otherwise it's not.  The non-false value returned
-- will be passed as the last parameter to the ondrop() callback of the target
-- widget.
function rtk.Widget:ondragstart(event) return false end

-- Called when a currently dragging widget has been dropped.  Return value
-- has no significance.
function rtk.Widget:ondragend(event, dragarg) end

-- Called when a currently dragging widget is moving.
function rtk.Widget:ondragmousemove(event, dragarg) end

-- Called when a currently dragging widget is hovering over another widget.
-- If the callback returns true then the widget is considered to be a valid
-- drop target, in which case if the mouse button is released then ondrop()
-- will be called.
function rtk.Widget:ondropfocus(event, source, dragarg) return false end

-- Called after ondropfocus() when the mouse moves over top of a valid
-- drop target (i.e. ondropfocus() returned true).
function rtk.Widget:ondropmousemove(event, source, dragarg) end


-- Called after a ondropfocus() when the widget being dragged leaves the
-- target widget's bounding box.
function rtk.Widget:ondropblur(event, source, dragarg) end

-- Called when a valid draggable widget has been dropped onto a valid
-- drop target.  The drop target receives the callback.  The last
-- parameter is the user arg that was returned by ondragstart() of the
-- source widget.
--
-- Returning true indicates the drop was received, in which case the
-- event is marked as handled. Otherwise the drop will passthrough to
-- lower z-indexed widgets.
function rtk.Widget:ondrop(event, source, dragarg)
    return false
end


-- Called after a reflow occurs on the widget, for example when the geometry
-- of the widget (or any of its parents) changes, or the widget's visibility
-- is toggled.
function rtk.Widget:onreflow() end


-------------------------------------------------------------------------------------------------------------

rtk.Viewport = class('rtk.Viewport', rtk.Widget)
rtk.Viewport.static.SCROLLBAR_NEVER = 0
rtk.Viewport.static.SCROLLBAR_ALWAYS = 1
rtk.Viewport.static.SCROLLBAR_HOVER = 2
rtk.Viewport.static._attr_filters.vscrollbar = {
    never=rtk.Viewport.SCROLLBAR_NEVER,
    always=rtk.Viewport.SCROLLBAR_ALWAYS,
    hover=rtk.Viewport.SCROLLBAR_HOVER
}
rtk.Viewport.static._attr_filters.hscrollbar = rtk.Viewport._attr_filters.vscrollbar

function rtk.Viewport:initialize(attrs)
    rtk.Widget.initialize(self)
    self.vx = 0
    self.vy = 0
    self.scrollbar_size = 15
    self.vscrollbar = rtk.Viewport.SCROLLBAR_HOVER
    self.vscrollbar_offset = 0
    self.vscrollbar_gutter = 50

    -- TODO: implement horizontal scrollbars
    self.hscrollbar = rtk.Viewport.SCROLLBAR_NEVER
    self.hscrollbar_offset = 0
    self.hscrollbar_gutter = 50

    self:setattrs(attrs)
    self:onattr('child', self.child, true)
    self._backingstore = nil
    -- If scroll*() is called then the offset is dirtied so that it can be clamped
    -- upon next draw or event.
    self._needs_clamping = false
    -- If not nil, then we need to emit onscroll() on next draw.  Value is the previous
    -- scroll position.  Initialize to non-nil value to ensure we trigger onscroll()
    -- after first draw.
    self._needs_onscroll = {0, 0}

    -- Scrollbar geometry updated during _reflow()
    self._vscrollx = 0
    self._vscrolly = 0
    self._vscrollh = 0
    self._vscrolla = {current=0, target=0, delta=0.05}
    self._vscroll_in_gutter = false
end

-- function rtk.Viewport:onmouseenter()
--     return false
-- end

function rtk.Viewport:_reflow(boxx, boxy, boxw, boxh, fillw, fillh, viewport)
    self.cx, self.cy = self:_resolvepos(boxx, boxy, self.x, self.y, boxx, boxy)
    local w, h = self:_resolvesize(boxw, boxh, self.w, self.h, boxw, boxh)

    local child_max_w = w - self.lpadding - self.rpadding
    local child_max_h = h - self.tpadding - self.bpadding

    -- FIXME: viewport dimensions calculation assumes vertical scrolling viewport
    if self.child and self.child.visible == true then
        local wx, wy, ww, wh = self.child:reflow(
            0,
            0,
            child_max_w,
            child_max_h,
            fillw,
            fillh,
            self
        )
        -- Computed size of viewport takes into account widget's size and x/y offset within
        -- the viewport.
        self.cw, self.ch = math.max(ww + wx, (fillw and w) or self.w or 0), h
        -- Truncate child dimensions to our constraining box unless the dimension was
        -- explicitly specified.
        if not self.w then
            self.cw = math.min(self.cw, boxw)
        end
        if not self.h then
            self.ch = math.min(self.ch, boxh)
        end
    else
        self.cw, self.ch = w, h
    end

    local innerw = self.cw - self.lpadding - self.rpadding
    local innerh = self.ch - self.tpadding - self.bpadding
    if not self._backingstore then
        self._backingstore = rtk.Image():create(innerw, innerh)
    else
        self._backingstore:resize(innerw, innerh, false)
    end

    -- Calculate geometry for scrollbars
    self._vscrollh = 0
    if self.child then
        if self.vscrollbar ~= rtk.Viewport.SCROLLBAR_NEVER and self.child.ch > innerh then
            self._vscrollx = self.cx + self.cw - self.scrollbar_size - self.vscrollbar_offset
            self._vscrolly = self.cy + self.ch * self.vy / self.child.ch + self.tpadding
            self._vscrollh = self.ch * innerh  / self.child.ch
        end
    end

    self._needs_clamping = true
end

function rtk.Viewport:onattr(attr, value, trigger)
    rtk.Widget.onattr(self, attr, value, trigger)
    if attr == 'child' and value then
        self.child.viewport = self
        self.child.parent = self
        rtk.queue_reflow()
    end
end

function rtk.Viewport:_draw(px, py, offx, offy, sx, sy, event)
    rtk.Widget._draw(self, px, py, offx, offy, sx, sy, event)
    local x = self.cx + offx + self.lpadding
    local y = self.cy + offy + self.tpadding
    if y + self.ch < 0 or y > rtk.h or self.ghost then
        -- Viewport is not visible
        return false
    end
    self:ondrawpre(offx, offy, event)
    self:_draw_bg(offx, offy, event)
    if self.child and self.child.realized then
        self:_clamp()
        -- Redraw the backing store, first "clearing" it according to what's currently painted
        -- underneath it.
        self._backingstore:drawfrom(gfx.dest, x, y, 0, 0, self._backingstore.width, self._backingstore.height)
        rtk.push_dest(self._backingstore.id)
        self.child:_draw(0, 0, -self.vx, -self.vy, sx + x, sy + y, event)
        rtk.pop_dest()
        self._backingstore:drawregion(0, 0, x, y, self.cw, self.ch)

        self:_draw_scrollbars(px, py, offx, offy, sx, sy, event)
    end

    self:_draw_borders(offx, offy, self.border, self.tborder, self.rborder, self.bborder, self.lborder)
    self:ondraw(offx, offy, event)
    if self._needs_onscroll then
        self:onscroll(self._needs_onscroll[1], self._needs_onscroll[2])
        self._needs_onscroll = nil
    end
end

function rtk.Viewport:_draw_scrollbars(px, py, offx, offy, sx, sy, event)
    local animate = self._vscrolla.current ~= self._vscrolla.target
    if self.vscrollbar == rtk.Viewport.SCROLLBAR_ALWAYS or
        (self.vscrollbar == rtk.Viewport.SCROLLBAR_HOVER and
            ((not rtk.dragging and self._vscroll_in_gutter) or animate or self._vscrolla.target>0)) then
        local scry = self.cy + self.ch * self.vy / self.child.ch + self.tpadding
        local scrx = self._vscrollx + offx
        local handle_hovering = point_in_box(rtk.mouse.x, rtk.mouse.y, scrx + sx, scry + sy,
                                                self.scrollbar_size, self.ch)
        if (handle_hovering and self._vscroll_in_gutter) or rtk.dragging == self then
            self._vscrolla.target = 0.44
            self._vscrolla.delta = 0.1
        elseif self._vscroll_in_gutter or self.vscrollbar == rtk.Viewport.SCROLLBAR_ALWAYS then
            self._vscrolla.target = 0.19
            self._vscrolla.delta = 0.1
        end
        if animate then
            local newval
            if self._vscrolla.current < self._vscrolla.target then
                newval = math.min(self._vscrolla.current + self._vscrolla.delta, self._vscrolla.target)
            else
                newval = math.max(self._vscrolla.current - self._vscrolla.delta, self._vscrolla.target)
            end
            self._vscrolla.current = newval
            rtk.queue_draw()
        end
        self:setcolor(rtk.theme.scrollbar)
        gfx.a = self._vscrolla.current
        gfx.rect(scrx, scry + offy, self.scrollbar_size, self._vscrollh, 1)
    end
end

function rtk.Viewport:_handle_event(offx, offy, event, clipped)
    rtk.Widget._handle_event(self, offx, offy, event, clipped)
    local x, y = self.cx + offx, self.cy + offy
    local hovering = point_in_box(rtk.mouse.x, rtk.mouse.y, x, y, self.cw, self.ch)
    local child_dragging = rtk.dragging and rtk.dragging.viewport == self

    if event.type == rtk.Event.MOUSEMOVE then
        local vscroll_in_gutter = false
        if child_dragging and rtk.dragging.show_scrollbar_on_drag then
            if rtk.mouse.y - 20 < y then
                self:scrollby(10, -math.max(5, math.abs(y - rtk.mouse.y)))
            elseif rtk.mouse.y + 20 > y + self.ch then
                self:scrollby(10, math.max(5, math.abs(y + self.ch - rtk.mouse.y)))
            end
            -- Show scrollbar when we have a child dragging.
            self._vscrolla.target = 0.19
            self._vscrolla.delta = 0.03
            -- XXX: commented out as it seems unnecessary but unsure why it was there
            -- to begin with.
            -- event:set_handled(self)
        elseif not rtk.dragging and not event.handled and hovering then
            if self.vscrollbar ~= rtk.Viewport.SCROLLBAR_NEVER and self._vscrollh > 0 then
                local gutterx = self._vscrollx + offx - self.vscrollbar_gutter
                local guttery = self.cy + offy
                -- Are we hovering in the scrollbar gutter?
                if point_in_box(rtk.mouse.x, rtk.mouse.y, gutterx, guttery,
                                self.vscrollbar_gutter + self.scrollbar_size, self.ch) then
                    vscroll_in_gutter = true
                    if rtk.mouse.x >= self._vscrollx + offx then
                        event:set_handled(self)
                    else
                        -- Ensure we queue draw if we leave the scrollbar handle but still in
                        -- the gutter.
                        rtk.queue_draw()
                    end
                end
            end
        end
        if vscroll_in_gutter ~= self._vscroll_in_gutter or self._vscrolla.current > 0 then
            self._vscroll_in_gutter = vscroll_in_gutter
            if not vscroll_in_gutter and not child_dragging then
                self._vscrolla.target = 0
                self._vscrolla.delta = 0.02
            end
            -- Ensure we redraw to reflect mouse leaving gutter.  But we
            -- don't mark the event as handled because we're ok with lower
            -- z-order widgets handling the mouseover as well.
            rtk.queue_draw()
        end
    elseif not event.handled and self._vscroll_in_gutter then
        if event.type == rtk.Event.MOUSEDOWN and rtk.mouse.x >= self._vscrollx + offx then
            local sy = self.cy + self.last_offy + self.sy
            local scrolly = self:_get_vscrollbar_screen_pos()
            if rtk.mouse.y < scrolly or rtk.mouse.y > scrolly + self._vscrollh then
                self:_handle_scrollbar(nil, self._vscrollh / 2, true)
            end
            event:set_handled(true)
        end
    end

    if (not event.handled or event.type == rtk.Event.MOUSEMOVE) and self.child and self.child.visible and self.child.realized then
        self:_clamp()
        self.child:_handle_event(x - self.vx + self.lpadding, y - self.vy + self.tpadding,
                                 event, clipped or not hovering)
    end
    if hovering and not event.handled and event.type == rtk.Event.MOUSEWHEEL and not event.ctrl then
        self:scrollby(0, event.wheel)
        event:set_handled(self)
    end
end

function rtk.Viewport:_get_vscrollbar_screen_pos()
    return self.last_offy + self.sy + self.cy + self.ch * self.vy / self.child.ch + self.tpadding
end

function rtk.Viewport:_handle_scrollbar(hoffset, voffset, gutteronly)
    if voffset ~= nil then
        local innerh = self.ch - self.tpadding - self.bpadding
        -- Screen coordinate of the Viewport widget
        local vsy = self.cy + self.last_offy + self.sy
        -- Screen coordinate of the scrollbar
        if gutteronly then
            local ssy = self:_get_vscrollbar_screen_pos()
            if rtk.mouse.y >= ssy and rtk.mouse.y <= ssy + self._vscrollh then
                -- Mouse is not in the gutter.
                return false
            end
        end
        local pct = clamp(rtk.mouse.y - vsy - voffset, 0, innerh) / innerh
        local target = pct * (self.child.ch)
        self:scrollto(self.vx, target)
    end
end

function rtk.Viewport:ondragstart(event)
    if self._vscroll_in_gutter then
        if rtk.mouse.x >= self._vscrollx + self.last_offx + self.sx then
            rtk.droppable = false
            return {true, rtk.mouse.y - self:_get_vscrollbar_screen_pos()}
        end
    end
    return false
end

function rtk.Viewport:ondragmousemove(event, arg)
    local vscrollbar, offset = table.unpack(arg)
    if vscrollbar then
        self:_handle_scrollbar(nil, offset, false)

    end
end

function rtk.Viewport:ondragend(event)
    -- In case we release the mouse in a different location (off the scrollbar
    -- handle or even outside the gutter), ensure the new state gets redrawn.
    rtk.queue_draw()
    return true
end

-- Scroll functions blindly accept the provided positions in case the child has not yet been
-- reflowed.  The viewport offsets will be clamped on next draw or event.
function rtk.Viewport:scrollby(offx, offy)
    self:scrollto(self.vx + offx, self.vy + offy)
end

function rtk.Viewport:scrollto(x, y)
    if x ~= self.vx or y ~= self.vy then
        self._needs_clamping = true
        -- Ensure we emit onscroll() after our next draw.
        self._needs_onscroll = {self.vx, self.vy}
        self.vx = x
        self.vy = y
        rtk.queue_draw()
    end
end

-- Clamp viewport position to fit child's current dimensions.  Caller must ensure child
-- has been realized.
function rtk.Viewport:_clamp()
    if self._needs_clamping then
        -- Clamp viewport position to fit child's current dimensions
        self.vx = clamp(self.vx, 0, math.max(0, self.child.cw - self.cw + self.lpadding + self.rpadding))
        self.vy = clamp(self.vy, 0, math.max(0, self.child.ch - self.ch + self.tpadding + self.bpadding))
        self._needs_clamping = false
    end
end

function rtk.Viewport:onscroll() end

-------------------------------------------------------------------------------------------------------------

rtk.Container = class('rtk.Container', rtk.Widget)
-- Flexspaces can be added to boxes to consume all remaining available space
-- (depending on box dimension) not needed by siblings in the same box.
--
-- BEWARE: Nesting boxes where the inner box is a non-expanded child of the
-- outer box and has a flexspace will consume all remaining space from the outer
-- box, even if the outer box has subsequent children.  Children after the
-- flexspace will have no more available room (their bounding box will be 0).
rtk.Container.static.FLEXSPACE = nil

function rtk.Container:initialize(attrs)
    rtk.Widget.initialize(self)
    -- Maps the child's position idx to the widget object
    self.children = {}
    -- Children from last reflow().  This list is the one that's drawn on next
    -- draw() rather than self.children, in case a child is added or removed
    -- in an event handler invoked from draw()
    self._reflowed_children = {}
    -- Ordered distinct list of z-indexes for reflowed children.  Generated by
    -- _determine_zorders().  Used to ensure we draw and propagate events to
    -- children in the correct order.
    self._z_indexes = {}
    self.spacing = 0
    self.bg = nil
    self.focusable = false
    self:setattrs(attrs)
end

function rtk.Container:onmouseenter(event)
    if self.bg or self.focusable then
        -- We have a background, block widgets underneath us from receiving the event.
        return event:set_handled(self)
    end
end

function rtk.Container:onmousemove(event)
    if self.hovering then
        return event:set_handled(self)
    end
end

function rtk.Container:clear()
    self.children = {}
    rtk.queue_reflow()
end

function rtk.Container:_reparent_child(child)
    if child then
        -- Yay mark and sweep GC!
        child.parent = self
    end
end

function rtk.Container:_unparent_child(pos)
    local child = self.children[pos][1]
    if child then
        child.parent = nil
    end
end

function rtk.Container:insert(pos, widget, attrs)
    self:_reparent_child(widget)
    table.insert(self.children, pos, {widget, self:_filter_attrs(attrs)})
    rtk.queue_reflow()
    return widget
end

function rtk.Container:add(widget, attrs)
    self:_reparent_child(widget)
    self.children[#self.children+1] = {widget, self:_filter_attrs(attrs)}
    rtk.queue_reflow()
    return widget
end

function rtk.Container:replace(pos, widget, attrs)
    self:_unparent_child(pos)
    self:_reparent_child(widget)
    self.children[pos] = {widget, self:_filter_attrs(attrs)}
    rtk.queue_reflow()
    return widget
end

function rtk.Container:remove_index(index)
    self:_unparent_child(index)
    table.remove(self.children, index)
    rtk.queue_reflow()
end

function rtk.Container:remove(widget)
    local n = self:get_child_index(widget)
    if n ~= nil then
        self:remove_index(n)
        return n
    end
end

function rtk.Container:_filter_attrs(attrs)
    if attrs then
        for k, v in pairs(attrs) do
            attrs[k] = self:_filter_attr(k, v)
        end
        return attrs
    else
        return {}
    end
end

-- Moves an existing child to a new index.  Out-of-bounds indexes
-- are clamped.  Returns true if the widget was reordered, or false if
-- the reorder would have resulted in a no-op.
function rtk.Container:reorder(widget, targetidx)
    local srcidx = self:get_child_index(widget)
    if srcidx ~= nil and srcidx ~= targetidx and (targetidx <= srcidx or targetidx - 1 ~= srcidx) then
        widgetattrs = table.remove(self.children, srcidx)
        local org = targetidx
        if targetidx > srcidx then
            targetidx = targetidx - 1
        end
        table.insert(self.children, clamp(targetidx, 1, #self.children + 1), widgetattrs)
        rtk.queue_reflow()
        return true
    else
        return false
    end
end

function rtk.Container:reorder_before(widget, target)
    local targetidx = self:get_child_index(target)
    return self:reorder(widget, targetidx)
end

function rtk.Container:reorder_after(widget, target)
    local targetidx = self:get_child_index(target)
    return self:reorder(widget, targetidx + 1)
end

function rtk.Container:get_child(idx)
    if idx < 0 then
        -- Negative indexes offset from end of children list
        idx = #self.children + idx + 1
    end
    return self.children[idx][1]
end


-- XXX: this is O(n). Containers could  keep a map of children by
-- their ids (which are globally unique) to the index.
function rtk.Container:get_child_index(child)
    for n, widgetattrs in ipairs(self.children) do
        local widget, _ = table.unpack(widgetattrs)
        if widget == child then
            return n
        end
    end
end


function rtk.Container:_handle_event(offx, offy, event, clipped)
    local x, y = self.cx + offx, self.cy + offy

    if y + self.ch < 0 or y > rtk.h or self.ghost then
        -- Container is not visible
        return false
    end

    -- Handle events from highest z-index to lowest.  Children at the same z level are
    -- processed in reverse order, which is the opposite order than they're drawn. So
    -- elements at the same z level that are painted above others will receive events
    -- first.
    local zs = self._z_indexes
    for zidx = #zs, 1, -1 do
        local zchildren = self._reflowed_children[zs[zidx]]
        local nzchildren = zchildren and #zchildren or 0
        for cidx = nzchildren, 1, -1 do
            local widget, attrs = table.unpack(zchildren[cidx])
            if widget ~= rtk.Container.FLEXSPACE and widget.visible == true and widget.realized then
                if widget.position == rtk.Widget.FIXED then
                    -- Handling viewport and non-viewport cases separately here is inelegant in
                    -- how it blurs the layers too much, but I don't see a cleaner way.
                    if self.viewport then
                        widget:_handle_event(offx + self.viewport.vx, offy + self.viewport.vy, event, clipped)
                    else
                        widget:_handle_event(self.cx + (self.last_offx or 0),
                                             self.cy + (self.last_offy or 0),
                                             event, clipped)
                    end
                else
                    widget:_handle_event(x, y, event, clipped)
                end

                -- It's tempting to break if the event was handled, but even if it was, we
                -- continue to invoke the child handlers to ensure that e.g. children no longer
                -- hovering can trigger onmouseleave() or lower z-index children under the mouse
                -- cursor have the chance to declare as hovering.
            end
        end
    end

    -- Give the container itself the opportunity to handle the event.  For example,
    -- if we have a background defined or we're focused, then we want to prevent
    -- mouseover events from falling through to lower z-index widgets that are
    -- obscured by the container.  Also if we're dragging with mouse button
    -- pressed, the container needs to have the opportunity to serve as a drop
    -- target.
    rtk.Widget._handle_event(self, offx, offy, event, clipped)
end


function rtk.Container:_draw(px, py, offx, offy, sx, sy, event)
    rtk.Widget._draw(self, px, py, offx, offy, sx, sy, event)
    local x, y = self.cx + offx, self.cy + offy

    if y + self.ch < 0 or y > rtk.h or self.ghost then
        -- Container is not visible
        return false
    end

    self:ondrawpre(offx, offy, event)
    self:_draw_bg(offx, offy, event)

    -- Draw children from lowest z-index to highest.  Children at the same z level are
    -- drawn in insertion order.
    for _, z in ipairs(self._z_indexes) do
        for _, widgetattrs in ipairs(self._reflowed_children[z]) do
            local widget, attrs = table.unpack(widgetattrs)
            if widget ~= rtk.Container.FLEXSPACE and widget.realized then
                local wx, wy = x, y
                if widget.position == rtk.Widget.FIXED then
                    wx = self.cx + px
                    wy = self.cy + py
                end
                widget:_draw(self.cx + px, self.cy + py, wx, wy, sx, sy, event)
                -- widget:draw_debug_box(wx, wy)
            end
        end
    end
    self:_draw_borders(offx, offy, self.border, self.tborder, self.rborder, self.bborder, self.lborder)
    self:ondraw(offx, offy, event)
end

function rtk.Container:_add_reflowed_child(widgetattrs, z)
    local z_children = self._reflowed_children[z]
    if z_children then
        z_children[#z_children+1] = widgetattrs
    else
        self._reflowed_children[z] = {widgetattrs}
    end
end

function rtk.Container:_determine_zorders()
    zs = {}
    for z in pairs(self._reflowed_children) do
        zs[#zs+1] = z
    end
    table.sort(zs)
    self._z_indexes = zs
end

function rtk.Container:_reflow(boxx, boxy, boxw, boxh, fillw, filly, viewport)
    local x, y = self:_resolvepos(boxx, boxy, self.x, self.y, boxx, boxy)
    local w, h = self:_resolvesize(boxw, boxh, self.w, self.h, boxw, boxh)

    local child_w = w - self.lpadding - self.rpadding
    local child_h = h - self.tpadding - self.bpadding

    local innerw, innerh = 0, 0
    self._reflowed_children = {}

    for _, widgetattrs in ipairs(self.children) do
        local widget, attrs = table.unpack(widgetattrs)
        if widget.visible == true then
            local lpadding, rpadding = attrs.lpadding or 0, attrs.rpadding or 0
            local tpadding, bpadding = attrs.tpadding or 0, attrs.bpadding or 0

            local wx, wy, ww, wh = widget:reflow(
                self.lpadding + lpadding,
                self.tpadding + tpadding,
                math.max(child_w - lpadding - rpadding, attrs.minw or 0),
                math.max(child_h - tpadding - bpadding, attrs.minh or 0),
                attrs.fillw,
                attrs.fillh,
                viewport
            )
            ww = math.max(ww, attrs.minw or 0)
            wh = math.max(wh, attrs.minh or 0)
            if attrs.halign == rtk.Widget.RIGHT then
                widget.cx = wx + (w - ww)
                widget.box[1] = w - ww
            elseif attrs.halign == rtk.Widget.CENTER then
                widget.cx = wx + (w - ww) / 2
                widget.box[1] = (w - ww) / 2
            end
            if attrs.valign == rtk.Widget.BOTTOM then
                widget.cy = wy + (h - wh)
                widget.box[2] = h - wh
            elseif attrs.valign == rtk.Widget.CENTER then
                widget.cy = wy + (h - wh) / 2
                widget.box[2] = (h - wh) / 2
            end
            -- Expand the size of the container accoridng to the child's size
            -- and x,y coordinates offset within the container (now that any
            -- repositioning has been completed caused by alignment above).
            innerw = math.max(innerw, ww + widget.cx - self.lpadding)
            innerh = math.max(innerh, wh + widget.cy - self.tpadding)
            self:_add_reflowed_child(widgetattrs, attrs.z or widget.z or 0)
        else
            widget.realized = false
        end
    end

    self:_determine_zorders()

    -- Set our own dimensions, so add self padding to inner dimensions
    outerw = innerw + self.lpadding + self.rpadding
    outerh = innerh + self.tpadding + self.bpadding

    self.cx, self.cy, self.cw, self.ch = x, y, math.max(outerw, self.w or 0), math.max(outerh, self.h or 0)
end


-------------------------------------------------------------------------------------------------------------
rtk.Box = class('rtk.Box', rtk.Container)
rtk.Box.static.HORIZONTAL = 1
rtk.Box.static.VERTICAL = 2
rtk.Box.static.FILL_NONE = 0
rtk.Box.static.FILL_TO_PARENT = 1
rtk.Box.static.FILL_TO_SIBLINGS = 2

rtk.Box.static._attr_filters.fillw = {
    none=rtk.Box.FILL_NONE,
    parent=rtk.Box.FILL_TO_PARENT,
    siblings=rtk.Box.FILL_TO_SIBLINGS,
}
rtk.Box.static._attr_filters.fillh = rtk.Box.static._attr_filters.fillw

function rtk.Box:initialize(direction, attrs)
    self.direction = direction
    rtk.Container.initialize(self, attrs)
end

function rtk.Box:_filter_attr(attr, value)
    if attr == 'fillw' or attr == 'fillh' then
        if value == false then
            return rtk.Box.FILL_NONE
        elseif value == true then
            return rtk.Box.FILL_TO_PARENT
        end
    end
    return rtk.Widget._filter_attr(self, attr, value)
end


function rtk.Box:_reflow(boxx, boxy, boxw, boxh, fillw, fillh, viewport)
    self.cx, self.cy = self:_resolvepos(boxx, boxy, self.x, self.y, boxx, boxy)
    local w, h = self:_resolvesize(boxw, boxh, self.w, self.h, boxw, boxh)

    local child_w = w - self.lpadding - self.rpadding
    local child_h = h - self.tpadding - self.bpadding

    local innerw, innerh, expand_unit_size = self:_reflow_step1(child_w, child_h, viewport)
    -- local s1w, s1h = innerw, innerh
    local innerw, innerh = self:_reflow_step2(child_w, child_h, innerw, innerh, expand_unit_size, viewport)

    -- Set our own dimensions, so add self padding to inner dimensions
    outerw = innerw + self.lpadding + self.rpadding
    outerh = innerh + self.tpadding + self.bpadding

    -- self.w/self.h could be negative or fractional, which is ok because
    -- resolvesize() returns the correct value.  If that's the case, force fill
    -- to be enabled so our cw/ch calculation below uses the resolved values.
    if self.w and self.w < 1.0 then
        fillw = true
    end
    if self.h and self.h < 1.0 then
        fillh = true
    end
    self.cw = math.max(outerw, (fillw and w) or self.w or 0)
    self.ch = math.max(outerh, (fillh and h) or self.h or 0)
    -- log.debug("rtk: %s (box): box=%s,%s  expand=%s spacing=%s  fill=%s,%s  inner=%s,%s (s1=%s,%s)   wh=%s,%s -> cxy=%s,%s cwh=%s,%s", self.id, boxw, boxh, expand_unit_size, self.spacing, fillw, fillh, innerw, innerh, s1w, s1h, w, h, self.cx, self.cy, self.cw, self.ch)
end


-- First pass over non-expanded children to compute available width/height
-- remaining to spread between expanded children.
function rtk.Box:_reflow_step1(w, h, viewport)
    local expand_units = 0
    local remaining_size = self.direction == 1 and w or h
    local maxw, maxh = 0, 0
    local spacing = 0
    self._reflowed_children = {}
    for n, widgetattrs in ipairs(self.children) do
        local widget, attrs = table.unpack(widgetattrs)
        if widget == rtk.Container.FLEXSPACE then
            expand_units = expand_units + (attrs.expand or 1)
            spacing = 0
        elseif widget.visible == true then
            local ww, wh = 0, 0
            local minw = attrs.minw or 0
            local minh = attrs.minh or 0
            local lpadding, rpadding = attrs.lpadding or 0, attrs.rpadding or 0
            local tpadding, bpadding = attrs.tpadding or 0, attrs.bpadding or 0
            -- Reflow at 0,0 coords just to get the native dimensions.  Will adjust position in second pass.
            if not attrs.expand or attrs.expand == 0 then
                if self.direction == rtk.Box.HORIZONTAL then
                    local child_maxw = remaining_size - lpadding - rpadding - spacing
                    child_maxw = math.max(child_maxw, minw)
                    local child_maxh = math.max(minh, h - tpadding - bpadding)
                    _, _, ww, wh = widget:reflow(
                        0,
                        0,
                        child_maxw,
                        child_maxh,
                        nil,
                        attrs.fillh == rtk.Box.FILL_TO_PARENT,
                        viewport
                    )
                    ww = math.max(ww, minw)
                else
                    local child_maxw = math.max(minw, w - lpadding - rpadding)
                    local child_maxh = remaining_size - tpadding - bpadding - spacing
                    child_maxh = math.max(child_maxh, minh)
                    _, _, ww, wh = widget:reflow(
                        0,
                        0,
                        child_maxw,
                        child_maxh,
                        attrs.fillw == rtk.Box.FILL_TO_PARENT,
                        nil,
                        viewport
                    )
                    wh = math.max(wh, minh)
                end
                maxw = math.max(maxw, ww + lpadding + rpadding)
                maxh = math.max(maxh, wh + tpadding + bpadding)
                if self.direction == rtk.Box.HORIZONTAL then
                    remaining_size = remaining_size - ww - lpadding - rpadding - spacing
                else
                    remaining_size = remaining_size - wh - tpadding - bpadding - spacing
                end
            else
                expand_units = expand_units + attrs.expand
            end
            -- Stretch applies to the opposite direction of the box, unlike expand
            -- which is the same direction.  So e.g. stretch in a VBox will force the
            -- box's width to fill its parent.
            if self.direction == rtk.Box.VERTICAL and attrs.stretch then
                maxw = w
            elseif self.direction == rtk.Box.HORIZONTAL and attrs.stretch then
                maxh = h
            end
            spacing = attrs.spacing or self.spacing
            self:_add_reflowed_child(widgetattrs, attrs.z or widget.z or 0)
        else
            widget.realized = false
        end
    end
    self:_determine_zorders()
    local expand_unit_size = expand_units > 0 and remaining_size / expand_units or 0
    return maxw, maxh, expand_unit_size
end


-------------------------------------------------------------------------------------------------------------
rtk.VBox = class('rtk.VBox', rtk.Box)

function rtk.VBox:initialize(attrs)
    rtk.Box.initialize(self, rtk.Box.VERTICAL, attrs)
end

-- Second pass over all children
function rtk.VBox:_reflow_step2(w, h, maxw, maxh, expand_unit_size, viewport)
    local offset = 0
    local spacing = 0
    local third_pass = {}
    for n, widgetattrs in ipairs(self.children) do
        local widget, attrs = table.unpack(widgetattrs)
        if widget == rtk.Container.FLEXSPACE then
            offset = offset + self.tpadding + expand_unit_size * (attrs.expand or 1)
            spacing = 0
            -- Ensure box size reflects flexspace in case this is the last child in the box.
            maxh = math.max(maxh, offset)
        elseif widget.visible == true then
            local wx, wy, ww, wh
            local minw = attrs.minw or 0
            local minh = attrs.minh or 0
            local lpadding, rpadding = attrs.lpadding or 0, attrs.rpadding or 0
            local tpadding, bpadding = attrs.tpadding or 0, attrs.bpadding or 0
            if attrs.expand and attrs.expand > 0 then
                -- This is an expanded child which was not reflown in pass 1, so do it now.
                local child_maxw = math.max(minw, w - lpadding - rpadding)
                local child_maxh = (expand_unit_size * attrs.expand) - tpadding - bpadding - spacing
                child_maxh = math.floor(math.max(child_maxh, minh))
                wx, wy, ww, wh = widget:reflow(
                    self.lpadding + lpadding,
                    offset + self.tpadding + tpadding + spacing,
                    child_maxw,
                    child_maxh,
                    attrs.fillw and attrs.fillw ~= 0,
                    attrs.fillh and attrs.fillh ~= 0,
                    viewport
                )
                if attrs.halign == rtk.Widget.CENTER then
                    widget.cx = wx + (maxw - ww) / 2
                elseif attrs.halign == rtk.Widget.RIGHT then
                    widget.cx = wx + maxw - ww
                end
                if not attrs.fillh or attrs.fillh == 0 then
                    -- We're expanding but not filling, so we want the child to use what it needs
                    -- but for purposes of laying out the box, treat it as if it's using child_maxh.
                    if attrs.valign == rtk.Widget.BOTTOM then
                        widget.cy = wy + (child_maxh - wh)
                        widget.box[2] = child_maxh - wh
                    elseif attrs.valign == rtk.Widget.CENTER then
                        widget.cy = wy + (child_maxh - wh) / 2
                        widget.box[2] = (child_maxh - wh) / 2
                    end
                else
                    wh = child_maxh
                end
            else
                -- Non-expanded widget with native size, already reflown in pass 1.  Just need
                -- to adjust position.
                local offx = self.lpadding + lpadding
                if attrs.halign == rtk.Widget.CENTER then
                    offx = (offx - rpadding) + (maxw - widget.cw) / 2
                elseif attrs.halign == rtk.Widget.RIGHT then
                    offx = offx + maxw - widget.cw
                end
                local offy = offset + self.tpadding + tpadding + spacing
                if attrs.fillw ~= rtk.Box.FILL_TO_SIBLINGS then
                    widget.cx = widget.cx + offx
                    widget.cy = widget.cy + offy
                    widget.box[1] = offx
                    widget.box[2] = offy
                else
                    third_pass[#third_pass+1] = {widget, offx, offy}
                end
                ww, wh = widget.cw, math.max(widget.ch, minh)
            end
            offset = offset + wh + tpadding + spacing + bpadding
            maxw = math.max(maxw, ww)
            maxh = math.max(maxh, offset)
            spacing = attrs.spacing or self.spacing
        end
    end
    if #third_pass > 0 then
        for n, widgetinfo in ipairs(third_pass) do
            local widget, ox, oy = table.unpack(widgetinfo)
            widget:reflow(ox, oy, maxw, child_maxh, true, nil, viewport)
        end
    end
    return maxw, maxh
end



-------------------------------------------------------------------------------------------------------------

rtk.HBox = class('rtk.HBox', rtk.Box)

function rtk.HBox:initialize(attrs)
    rtk.Box.initialize(self, rtk.Box.HORIZONTAL, attrs)
end

-- TODO: there is too much in common here with VBox:_reflow_step2().  This needs
-- to be refactored better, by using more tables with indexes rather than unpacking
-- to separate variables.
function rtk.HBox:_reflow_step2(w, h, maxw, maxh, expand_unit_size, viewport)
    local offset = 0
    local spacing = 0
    local third_pass = {}
    for n, widgetattrs in ipairs(self.children) do
        local widget, attrs = table.unpack(widgetattrs)
        if widget == rtk.Container.FLEXSPACE then
            offset = offset + self.lpadding + expand_unit_size * (attrs.expand or 1)
            spacing = 0
            -- Ensure box size reflects flexspace in case this is the last child in the box.
            maxw = math.max(maxw, offset)
        elseif widget.visible == true then
            local wx, wy, ww, wh
            local lpadding, rpadding = attrs.lpadding or 0, attrs.rpadding or 0
            local tpadding, bpadding = attrs.tpadding or 0, attrs.bpadding or 0
            local minw = attrs.minw or 0
            local minh = attrs.minh or 0
            if attrs.expand and attrs.expand > 0 then
                -- This is an expanded child which was not reflown in pass 1, so do it now.
                local child_maxw = (expand_unit_size * attrs.expand) - lpadding - rpadding - spacing
                child_maxw = math.floor(math.max(child_maxw, minw))
                local child_maxh = math.max(minh, h - tpadding - bpadding)
                wx, wy, ww, wh = widget:reflow(
                    offset + self.lpadding + lpadding + spacing,
                    self.tpadding + tpadding,
                    child_maxw,
                    child_maxh,
                    attrs.fillw == rtk.Box.FILL_TO_PARENT,
                    attrs.fillh == rtk.Box.FILL_TO_PARENT,
                    viewport
                )
                if attrs.valign == rtk.Widget.CENTER then
                    widget.cy = wy + (maxh - wh) / 2
                elseif attrs.valign == rtk.Widget.BOTTOM then
                    widget.cy = wy + maxh - wh
                end
                if not attrs.fillw or attrs.fillw == 0 then
                    if attrs.halign == rtk.Widget.RIGHT then
                        widget.cx = wx + (child_maxw - ww)
                        widget.box[1] = child_maxw - ww
                    elseif attrs.halign == rtk.Widget.CENTER then
                        widget.cx = wx + (child_maxw - ww) / 2
                        widget.box[1] = (child_maxw - ww) / 2
                    end
                else
                    ww = child_maxw
                end
            else
                -- Non-expanded widget with native size, already reflown in pass 1.  Just need
                -- to adjust position.
                local offy = self.tpadding + tpadding
                if attrs.valign == rtk.Widget.CENTER then
                    offy = (offy - bpadding) + (maxh - widget.ch) / 2
                elseif attrs.valign == rtk.Widget.BOTTOM then
                    offy = offy + maxh - widget.ch
                end
                local offx = offset + self.lpadding + lpadding + spacing
                if attrs.fillh ~= rtk.Box.FILL_TO_SIBLINGS then
                    widget.cx = widget.cx + offx
                    widget.cy = widget.cy + offy
                    widget.box[1] = offx
                    widget.box[2] = offy
                else
                    third_pass[#third_pass+1] = {widget, offx, offy}
                end
                ww, wh = math.max(widget.cw, minw), widget.ch
            end
            offset = offset + ww + lpadding + spacing + rpadding
            maxw = math.max(maxw, offset)
            maxh = math.max(maxh, wh)
            spacing = attrs.spacing or self.spacing
        end
    end
    if #third_pass > 0 then
        for n, widgetinfo in ipairs(third_pass) do
            local widget, ox, oy = table.unpack(widgetinfo)
            widget:reflow(ox, oy, child_maxw, maxh, nil, true, viewport)
        end
    end
    return maxw, maxh
end


-------------------------------------------------------------------------------------------------------------

rtk.Button = class('rtk.Button', rtk.Widget)
-- Flags
rtk.Button.static.FULL_SURFACE = 0
rtk.Button.static.FLAT_ICON = 1
rtk.Button.static.FLAT_LABEL = 2
rtk.Button.static.FLAT = 1 | 3
rtk.Button.static.ICON_RIGHT = 4
rtk.Button.static.NO_HOVER = 8
rtk.Button.static.NO_SEPARATOR = 16

local function _filter_image(value)
    if type(value) == 'string' then
        return rtk.Image.make_icon(value)
    else
        return value
    end
end

rtk.Button.static._attr_filters.icon = _filter_image


function rtk.Button:initialize(attrs)
    rtk.Widget.initialize(self)
    self.focusable = true
    self.label = nil
    -- If true, wraps the label to the bounding box on reflow.
    self.wrap = false
    self.icon = nil
    -- Icon vertical alignment when text is wrapped
    self.ivalign = rtk.Widget.CENTER
    self.color = rtk.theme.button
    -- Text color when label is drawn over button surface
    self.textcolor = rtk.theme.buttontext
    -- Text color when button surface isn't drawn
    self.textcolor2 = rtk.theme.text
    self.lspace = 10
    self.rspace = 5
    self.font, self.fontsize = table.unpack(rtk.fonts.button or rtk.fonts.default)
    self.fontscale = 1.0
    self.fontflags = 0
    self.hover = false
    self:setattrs(attrs)
    if not self.flags then
        self.flags = rtk.Button.FULL_SURFACE
        if self.icon == nil then
            self.flags = self.flags | rtk.Button.FLAT_ICON
        end
        if self.label == nil then
            self.flags = self.flags | rtk.Button.FLAT_LABEL
        end
    end
    -- The (if necessary) truncated label to fit the viewable label area
    self.vlabel = self.label
end

function rtk.Button:onmouseenter(event)
    return true
end

-- Returns the width, height, single-line height, and wrapped label.
--
-- The single-line height represents the height of the prewrapped label
-- when rendered with the current font.  This can be used for alignment
-- calculations.
function rtk.Button:_reflow_get_label_size(boxw, boxh)
    rtk.set_font(self.font, self.fontsize, self.fontscale, self.fontflags)
    return rtk.layout_gfx_string(self.label, self.wrap, true, boxw, boxh)
end

function rtk.Button:_reflow(boxx, boxy, boxw, boxh, fillw, fillh, viewport)
    self.cx, self.cy = self:_resolvepos(boxx, boxy, self.x, self.y, boxx, boxy)
    local w, h = self:_resolvesize(boxw, boxh, self.w, self.h)

    if w == nil and fillw then
        -- Requested to fill box width, so set inner width (box width minus internal padding)
        w = boxw - self.lpadding - self.rpadding
    end
    if h == nil and fillh then
        -- Requested to fill box height.
        h = boxh - self.tpadding - self.bpadding
    end

    if self.label ~= nil then
        -- Calculate the viewable portion of the label
        local lwmax = (w or boxw) - (self.lpadding + self.rpadding) * rtk.scale
        local lhmax = (h or boxh) - (self.tpadding + self.bpadding) * rtk.scale

        if self.icon then
            lwmax = lwmax - (self.icon.width + self.lspace + self.rspace) * rtk.scale
        end
        self.lw, self.lh, self.lhs, self.vlabel = self:_reflow_get_label_size(lwmax, lhmax)

        if self.icon ~= nil then
            self.cw = w or ((self.icon.width + self.lpadding + self.rpadding + self.lspace + self.rspace) * rtk.scale + self.lw)
            self.ch = h or (math.max(self.icon.height * rtk.scale, self.lh) + (self.tpadding + self.bpadding) * rtk.scale)
        else
            self.cw = (w and w * rtk.scale or self.lw) + (self.lpadding + self.rpadding) * rtk.scale
            self.ch = (h and h * rtk.scale or self.lh) + (self.tpadding + self.bpadding) * rtk.scale
        end

    elseif self.icon ~= nil then
        self.cw = w or (self.icon.width + self.lpadding + self.rpadding) * rtk.scale
        self.ch = h or (self.icon.height + self.tpadding + self.bpadding) * rtk.scale
    end
end


function rtk.Button:_draw(px, py, offx, offy, sx, sy, event)
    rtk.Widget._draw(self, px, py, offx, offy, sx, sy, event)
    local x, y = self.cx + offx, self.cy + offy
    local sx, sy, sw, sh = x, y, 0, 0

    if y + self.ch < 0 or y > rtk.h or self.ghost then
        -- Widget not viewable on viewport
        return false
    end

    -- TODO: finish support for alignment attributes
    local hover = event:is_widget_hovering(self) or self.hover
    local lx, ix, sepx = nil, nil, nil
    -- Default label color to surfaceless color and override if label is drawn on surface
    local textcolor = self.textcolor2
    local draw_icon_surface = self.flags & rtk.Button.FLAT_ICON == 0
    local draw_label_surface = self.flags & rtk.Button.FLAT_LABEL == 0
    local draw_hover = self.flags & rtk.Button.NO_HOVER == 0 or self.hover
    local draw_separator = false
    -- Button has both icon and label
    if self.icon ~= nil and self.label ~= nil then
        -- Either hovering or both icon and label need to be rendered on button surface
        if (hover and draw_hover) or (draw_icon_surface and draw_label_surface) then
            sw, sh = self.cw, self.ch
            textcolor = self.textcolor
            draw_separator = true
        -- Icon on surface with flat label
        elseif not draw_label_surface and draw_icon_surface and self.icon ~= nil then
            sw = (self.icon.width + self.lpadding + self.rpadding) * rtk.scale
            sh = self.ch
        end
        local iconwidth = (self.icon.width + self.lpadding) * rtk.scale
        if self.flags & rtk.Button.ICON_RIGHT == 0 then
            lx = sx + iconwidth + (self.lspace * rtk.scale)
            ix = sx + self.lpadding * rtk.scale
            sepx = sx + iconwidth + self.lspace/2
        else
            ix = x + self.cw - iconwidth
            sx = x + self.cw - sw
            lx = x + (self.lpadding + self.lspace) * rtk.scale
            sepx = ix + self.lspace / 2
        end
    -- Label but no icon
    elseif self.label ~= nil and self.icon == nil then
        if (hover and draw_hover) or draw_label_surface then
            sw, sh = self.cw, self.ch
            textcolor = self.textcolor
        end
        if self.halign == rtk.Widget.LEFT then
            lx = sx + self.lpadding * rtk.scale
        elseif self.halign == rtk.Widget.CENTER then
            lx = sx + (self.cw - self.lw) / 2
        elseif self.halign == rtk.Widget.RIGHT then
            lx = sx + (self.cw - self.lw) - self.rpadding * rtk.scale
        end
    -- Icon but no label
    elseif self.icon ~= nil and self.label == nil then
        ix = sx + self.lpadding * rtk.scale
        if (hover and draw_hover) or draw_icon_surface then
            sw, sh = self.cw, self.ch
        end
    end

    self:ondrawpre(offx, offy, event)
    local r, g, b, a = color2rgba(self.color)
    a = a * self.alpha
    if sw and sh and sw > 0 and sh > 0 then
        if hover and rtk.mouse.down ~= 0 and self:focused() then
            r, g, b = r*0.8, g*0.8, b*0.8
            gfx.gradrect(sx, sy, sw, sh, r, g, b, a,  0, 0, 0, 0,   -r/50, -g/50, -b/50, 0)
            gfx.set(1, 1, 1, 0.2 * self.alpha)
            gfx.rect(sx, sy, sw, sh, 0)
        else
            local mul = hover and 0.8 or 1
            local d = hover and 400 or -75
            gfx.gradrect(sx, sy, sw, sh, r, g, b, a*mul,  0, 0, 0, 0,   r/d, g/d, b/d, 0)
            if hover then
                gfx.set(r*1.3, g*1.3, b*1.3, self.alpha)
            else
                gfx.set(1, 1, 1, 0.1 * self.alpha)
            end
            gfx.rect(sx, sy, sw, sh, 0)
        end
        if sepx and draw_separator and self.flags & rtk.Button.NO_SEPARATOR == 0 then
            gfx.set(0, 0, 0, 0.3 * self.alpha)
            gfx.line(sepx, sy + 1, sepx, sy + sh - 2)
        end
    end
    gfx.set(1, 1, 1, self.alpha)
    if self.icon then
        local iy
        if self.vlabel and self.ivalign ~= rtk.Widget.CENTER then
            if self.ivalign == rtk.Widget.BOTTOM then
                iy = sy + self.ch - self.icon.height * rtk.scale
            else
                iy = sy
            end
        else
            -- Center icon vertically according to computed height
            iy = sy + (self.ch - self.icon.height * rtk.scale) / 2
        end
        self:_draw_icon(ix, iy, hover)
    end
    if self.vlabel then
        gfx.x = lx
        -- XXX: it's unclear why we need to fudge the extra pixel on
        -- OS X but it fixes alignment.
        gfx.y = sy + (self.ch - self.lh) / 2 + (rtk.os.mac and 1 or 0)
        rtk.set_font(self.font, self.fontsize, self.fontscale, self.fontflags)
        self:setcolor(textcolor)
        gfx.drawstr(self.vlabel)
    end
    self:ondraw(offx, offy, event)
end

function rtk.Button:_draw_icon(x, y, hovering)
    self.icon:draw(x, y, rtk.scale, nil, self.alpha)
end

function rtk.Button:onclick(event)
end


-------------------------------------------------------------------------------------------------------------

rtk.Entry = class('rtk.Entry', rtk.Widget)
rtk.Entry.static.MAX_WIDTH = 1024
rtk.Entry.static._attr_filters.icon = _filter_image

function rtk.Entry:initialize(attrs)
    rtk.Widget.initialize(self)
    self.focusable = true
    -- Width of the text field based on number of characters
    self.textwidth = nil
    -- Maximum number of characters allowed from input
    self.max = nil
    self.value = ''
    self.font, self.fontsize = table.unpack(rtk.fonts.entry or rtk.fonts.default)
    self.fontscale = 1.0
    self.lpadding = 5
    self.tpadding = 3
    self.rpadding = 5
    self.bpadding = 3
    self.icon = nil
    self.icon_alpha = 0.6
    self.label = ''
    self.color = rtk.theme.text
    self.bg = rtk.theme.entry_bg
    self.border = {rtk.theme.entry_border_focused}
    self.border_hover = {rtk.theme.entry_border_hover}
    self.cursor = rtk.mouse.cursors.beam

    self.caret = 1
    self.lpos = 1
    self.rpos = nil
    self.loffset = 0
    -- Character position where selection was started
    self.selanchor = nil
    -- Character position where where selection ends (which may be less than or
    -- greater than the anchor)
    self.selend = nil
    -- Array mapping character index to x offset
    self.positions = {0}
    self.image = rtk.Image()
    self.image:create()

    self.lpos = 5

    self:setattrs(attrs)
    self.caretctr = 0
    self._blinking = false
    self._dirty = false
    -- A table of prior states for ctrl-z undo.  Each entry is is an array
    -- of {text, caret, selanchor, selend}
    self._history = nil
    self._last_dblclick_time = 0
    self._num_dblclicks = 0

end

function rtk.Entry:onmouseenter(event)
    return true
end


function rtk.Entry:_reflow(boxx, boxy, boxw, boxh, fillw, fillh, viewport)
    local maxw, maxh = nil, nil
    if self.textwidth and not self.w then
        -- Compute dimensions based on font and size
        rtk.set_font(self.font, self.fontsize, self.fontscale, 0)
        maxw, maxh = gfx.measurestr(string.rep("D", self.textwidth))
    elseif not self.h then
        rtk.set_font(self.font, self.fontsize, self.fontscale, 0)
        _, maxh = gfx.measurestr("Dummy!")
    end

    self.cx, self.cy = self:_resolvepos(boxx, boxy, self.x, self.y, boxx, boxy)
    local w, h = self:_resolvesize(boxw, boxh, self.w, self.h,
                                   (not fillw and maxw) or (boxw - self.lpadding - self.rpadding),
                                   (not fillh and maxh) or (boxh - self.tpadding - self.bpadding))
    self.cw, self.ch = w + self.lpadding + self.rpadding, h + self.tpadding + self.bpadding

    self.image:resize(rtk.Entry.MAX_WIDTH, maxh)
    self:calcpositions()
    self:calcview()
    self._dirty = true
end

function rtk.Entry:calcpositions(startfrom)
    rtk.set_font(self.font, self.fontsize, self.fontscale, 0)
    -- Ok, this isn't exactly efficient, but it should be fine for sensibly sized strings.
    for i = (startfrom or 1), self.value:len() do
        local w, _ = gfx.measurestr(self.value:sub(1, i))
        self.positions[i + 1] = w
    end
end

function rtk.Entry:calcview()
    -- TODO: handle case where text is deleted from end, we want to keep the text right justified
    local curx = self.positions[self.caret]
    local curoffset = curx - self.loffset
    local contentw = self.cw - (self.lpadding + self.rpadding)
    if self.icon then
        contentw = contentw - self.icon.width - 5
    end
    if curoffset < 0 then
        self.loffset = curx
    elseif curoffset > contentw then
        self.loffset = curx - contentw
    end
end


function rtk.Entry:_rendertext(x, y)
    rtk.set_font(self.font, self.fontsize, self.fontscale, 0)
    self.image:drawfrom(gfx.dest, x + self.lpadding, y + self.tpadding,
                        self.loffset, 0, self.image.width, self.image.height)
    rtk.push_dest(self.image.id)

    if self.selanchor and self:focused() then
        local a, b  = self:get_selection_range()
        self:setcolor(rtk.theme.entry_selection_bg)
        gfx.rect(self.positions[a], 0, self.positions[b] - self.positions[a], self.image.height, 1)
    end

    self:setcolor(self.color)
    gfx.x, gfx.y = 0, 0
    gfx.drawstr(self.value)
    rtk.pop_dest()
    self._dirty = false
end

function rtk.Entry:onblur()
    if self.selanchor then
        -- There is a selection, so force a redraw to ensure the selection is
        -- hidden.
        self._dirty = true
    end
end

function rtk.Entry:_draw(px, py, offx, offy, sx, sy, event)
    if offy ~= self.last_offy or offx ~= self.last_offx then
        -- If we've scrolled within a viewport since last draw, force
        -- _rendertext() to repaint the background into the Entry's
        -- local backing store.
        self._dirty = true
    end
    rtk.Widget._draw(self, px, py, offx, offy, sx, sy, event)

    local x, y = self.cx + offx, self.cy + offy
    local focused = self:focused() and rtk.is_focused

    if (y + self.ch < 0 or y > rtk.h or self.ghost) and not focused then
        -- Widget not viewable on viewport
        return false
    end

    local hover = event:is_widget_hovering(self)

    self:ondrawpre(offx, offy, event)
    -- Paint background first because _rendertext() will copy to the backing store and
    -- render the text over top it.
    self:_draw_bg(offx, offy, event)

    if self._dirty then
        self:_rendertext(x, y)
    end

    local lpadding = self.lpadding
    if self.icon then
        local a = self.icon_alpha + (focused and 0.2 or 0)
        self.icon:draw(x + lpadding, y + (self.ch - self.icon.height * rtk.scale) / 2, rtk.scale, nil, a * self.alpha)
        lpadding = lpadding + self.icon.width + 5
    end

    self.image:drawregion(
        self.loffset, 0, x + lpadding, y + self.tpadding,
        self.cw - lpadding - self.rpadding, self.ch - self.tpadding - self.bpadding,
        nil, nil, self.alpha
    )

    if self.label and #self.value == 0 then
        rtk.set_font(self.font, self.fontsize, self.fontscale, rtk.fonts.ITALICS)
        gfx.x, gfx.y = x + lpadding, y + self.tpadding
        self:setcolor(self.color, 0.5)
        gfx.drawstr(self.label)
    end

    if hover then
        if not focused then
            self:_draw_borders(offx, offy, self.border_hover)
        end
    end
    if hover and event and event.type == rtk.Event.MOUSEDOWN then
        self.caret = self:_caret_from_mouse_event(x + sx, y + sy, event)
    end
    if focused then
        if not self._blinking then
            -- Run a "timer" in the background to queue a redraw when the
            -- cursor needs to blink.
            self:_blink()
        end
        self:_draw_borders(offx, offy, self.border)
        if self.caretctr % 32 < 16 then
            -- Draw caret
            local curx = x + self.positions[self.caret] + lpadding - self.loffset
            self:setcolor(self.color)
            gfx.line(curx, y + self.tpadding, curx, y + self.ch - self.bpadding, 0)
        end
    else
        self._blinking = false
    end
    self:ondraw(offx, offy, event)
end

function rtk.Entry:_blink()
    if self:focused() and rtk.is_focused then
        self._blinking = true
        local ctr = self.caretctr % 16
        self.caretctr = self.caretctr + 1
        if ctr == 0 then
            rtk.queue_draw()
        end
        reaper.defer(function() self:_blink() end)
    end
end

-- Given absolute coords of the text area, determine the caret position from
-- the mouse down event.
function rtk.Entry:_caret_from_mouse_event(x, y, event)
    local relx = self.loffset + event.x - x - (self.icon and (self.icon.width + 5) or 0)
    for i = 2, self.value:len() + 1 do
        if relx < self.positions[i] then
            return i - 1
        end
    end
    return self.value:len() + 1
end

function rtk.Entry:_get_word_left(spaces)
    local caret = self.caret
    if spaces then
        while caret > 1 and self.value:sub(caret - 1, caret - 1) == ' ' do
            caret = caret - 1
        end
    end
    while caret > 1 and self.value:sub(caret - 1, caret - 1) ~= ' ' do
        caret = caret - 1
    end
    return caret
end

function rtk.Entry:_get_word_right(spaces)
    local caret = self.caret
    local len = self.value:len()
    while caret <= len and self.value:sub(caret, caret) ~= ' ' do
        caret = caret + 1
    end
    if spaces then
        while caret <= len and self.value:sub(caret, caret) == ' ' do
            caret = caret + 1
        end
    end
    return caret
end


function rtk.Entry:select_all()
    self.selanchor = 1
    self.selend = self.value:len() + 1
    self._dirty = true
    rtk.queue_draw()
end

function rtk.Entry:select_range(a, b)
    local len = self.value:len()
    if len == 0 or not a then
        -- Regardless of what was asked, there is nothing to select.
        self.selanchor = nil
    else
        self.selanchor = math.max(1, a)
        self.selend = math.min(len + 1, b)
    end
    self._dirty = true
    rtk.queue_draw()
end

function rtk.Entry:get_selection_range()
    if self.selanchor then
        return math.min(self.selanchor, self.selend), math.max(self.selanchor, self.selend)
    end
end

function rtk.Entry:_copy_selection()
    if self.selanchor then
        local a, b = self:get_selection_range()
        local text = self.value:sub(a, b - 1)
        reaper.CF_SetClipboard(text)
    end
end

function rtk.Entry:delete_selection()
    if self.selanchor then
        self:_push_history()
        local a, b = self:get_selection_range()
        self:delete_range(a - 1, b)
        if self.caret > self.selanchor then
            self.caret = math.max(1, self.caret - (b-a))
        end
        self._dirty = true
        rtk.queue_draw()
        self:onchange()
    end
    return self.value:len()
end

function rtk.Entry:delete_range(a, b)
    self.value = self.value:sub(1, a) .. self.value:sub(b)
    self._dirty = true
end

function rtk.Entry:insert(text)
    -- FIXME: honor self.max based on current len and size of text
    self.value = self.value:sub(0, self.caret - 1) .. text .. self.value:sub(self.caret)
    self:calcpositions(self.caret)
    self.caret = self.caret + text:len()
    self._dirty = true
    rtk.queue_draw()
    self:onchange()
end

function rtk.Entry:_push_history()
    if not self._history then
        self._history = {}
    end
    self._history[#self._history + 1] = {self.value, self.caret, self.selanchor, self.selend}
end

function rtk.Entry:_pop_history()
    if self._history and #self._history > 0 then
        local state = table.remove(self._history, #self._history)
        self.value, self.caret, self.selanchor, self.selend = table.unpack(state)
        self._dirty = true
        self:calcpositions()
        rtk.queue_draw()
        self:onchange()
    end
end

function rtk.Entry:_handle_event(offx, offy, event, clipped)
    if event.handled then
        return
    end
    rtk.Widget._handle_event(self, offx, offy, event, clipped)
    if not self:focused() then
        return
    end
    if event.type == rtk.Event.KEY then
        if self:onkeypress(event) == false then
            return
        end
        event:set_handled(self)
        local len = self.value:len()
        local orig_caret = self.caret
        local selecting = event.shift
        if event.keycode == rtk.keycodes.LEFT then
            if event.ctrl then
                self.caret = self:_get_word_left(true)
            else
                self.caret = math.max(1, self.caret - 1)
            end
        elseif event.keycode == rtk.keycodes.RIGHT then
            if event.ctrl then
                self.caret = self:_get_word_right(true)
            else
                self.caret = math.min(self.caret + 1, len + 1)
            end
        elseif event.keycode == rtk.keycodes.HOME then
            self.caret = 1
        elseif event.keycode == rtk.keycodes.END then
            self.caret = self.value:len() + 1
        elseif event.keycode == rtk.keycodes.DELETE then
            if self.selanchor then
                self:delete_selection()
            else
                if event.ctrl then
                    self:_push_history()
                    self:delete_range(self.caret - 1, self:_get_word_right(true))
                else
                    self:delete_range(self.caret - 1, self.caret + 1)
                end
            end
            self:calcpositions(self.caret)
            self:onchange()
        elseif event.keycode == rtk.keycodes.BACKSPACE then
            if self.caret >= 1 then
                if self.selanchor then
                    self:delete_selection()
                else
                    if event.ctrl then
                        self:_push_history()
                        self.caret = self:_get_word_left(true)
                        self:delete_range(self.caret - 1, orig_caret)
                    else
                        self:delete_range(self.caret - 2, self.caret)
                        self.caret = math.max(1, self.caret - 1)
                    end
                end
                self:calcpositions(self.caret)
                self:onchange()
            end
        elseif event.char and not event.ctrl and (len == 0 or self.positions[len] < rtk.Entry.MAX_WIDTH) then
            len = self:delete_selection()
            self:insert(event.char)
            selecting = false
        elseif event.ctrl and event.char and not event.shift then
            if event.char == 'a' and len > 0 then
                self:select_all()
                -- Ensure selection doesn't get reset below because shift isn't pressed.
                selecting = nil
            elseif event.char == 'c' then
                self:_copy_selection()
                return
            elseif event.char == 'x' then
                self:_copy_selection()
                self:delete_selection()
            elseif event.char == 'v' then
                self:delete_selection()
                local fast = reaper.SNM_CreateFastString("")
                local str =  reaper.CF_GetClipboardBig(fast)
                self:insert(str)
                reaper.SNM_DeleteFastString(fast)
            elseif event.char == 'z' then
                self:_pop_history()
                selecting = nil
            end
        else
            return
        end
        if selecting then
            if not self.selanchor then
                self.selanchor = orig_caret
            end
            self.selend = self.caret
        elseif selecting == false then
            self.selanchor = nil
        end
        -- Reset blinker
        self.caretctr = 0
        self:calcview()
        self._dirty = true
        log.debug('keycode=%s char=%s caret=%s ctrl=%s shift=%s sel: %s-%s', event.keycode, event.char, self.caret, event.ctrl, event.shift, self.selanchor, self.selend)
    end
end

function rtk.Entry:ondragstart(event)
    self.selanchor = self.caret
    self.selend = self.caret
    return true
end

function rtk.Entry:ondragmousemove(event)
    local ax = self.last_offx + self.sx + self.cx
    local ay = self.last_offy + self.sy + self.cy
    local selend = self:_caret_from_mouse_event(ax, ay, event)
    if selend == self.selend then
        return
    end
    self.selend = selend
    -- This will force a reflow of this widget.
    self:attr('caret', selend)
end

function rtk.Entry:ondragend(event)
    -- Reset double click timer
    self.last_click_time  = 0
end

function rtk.Entry:_filter_attr(attr, value)
    if attr == 'value' then
        return value and tostring(value) or ''
    else
        return rtk.Widget._filter_attr(self, attr, value)
    end
end


function rtk.Entry:onattr(attr, value, trigger)
    -- Calling superclass here will queue reflow, which in turn will
    -- automatically dirty rendered text and calcview().
    rtk.Widget.onattr(self, attr, value, trigger)
    if attr == 'value' then
        self._history = nil
        self.selanchor = nil
        -- After setting value, ensure caret does not extend past end of value.
        if self.caret >= value:len() then
            self.caret = value:len() + 1
        end
        if trigger then
            self:onchange()
        end
    elseif attr == 'caret' then
        self.caret = clamp(value, 1, self.value:len() + 1)
    end
end

function rtk.Entry:onclick(event)
    if rtk.dragging ~= self then
        self:select_range(nil)
        rtk.Widget.focus(self)
    end
end

function rtk.Entry:ondblclick(event)
    if event.time - self._last_dblclick_time < 0.7 then
        self._num_dblclicks = self._num_dblclicks + 1
    else
        self._last_dblclick_time = event.time
        self._num_dblclicks = 1
    end

    if self._num_dblclicks == 2 then
        -- Triple click selects all text
        self:select_all()
    else
        local left = self:_get_word_left(false)
        local right = self:_get_word_right(true)
        self.caret = right
        self:select_range(left, right)
    end
end

function rtk.Entry:onchange() end

function rtk.Entry:onkeypress()
    return true
end


-------------------------------------------------------------------------------------------------------------


rtk.Label = class('rtk.Label', rtk.Widget)
rtk.Label.static._attr_filters.textalign = {
    left=rtk.Widget.LEFT,
    center=rtk.Widget.CENTER
}

function rtk.Label:initialize(attrs)
    rtk.Widget.initialize(self)
    self.label = 'Label'
    self.color = rtk.theme.text
    self.wrap = false
    self.truncate = true
    self.font, self.fontsize, self.fontflags = table.unpack(rtk.fonts.label or rtk.fonts.default)
    self.fontscale = 1.0
    self.textalign = rtk.Widget.LEFT
    self:setattrs(attrs)
end

function rtk.Label:_reflow(boxx, boxy, boxw, boxh, fillw, fillh, viewport)
    self.cx, self.cy = self:_resolvepos(boxx, boxy, self.x, self.y, boxx, boxy)
    local w, h = self:_resolvesize(boxw, boxh, self.w, self.h, fillw and boxw or nil, fillh and boxh or nil)

    local lw, lh
    rtk.set_font(self.font, self.fontsize, self.fontscale, self.fontflags)
    lw, lh, _, self.vlabel = rtk.layout_gfx_string(self.label, self.wrap, self.truncate,
                                                   boxw - self.lpadding - self.rpadding,
                                                   boxy - self.tpadding - self.bpadding,
                                                   self.textalign)

    if not w then
        w = lw + (self.lpadding + self.rpadding) * rtk.scale
    end
    if not h then
        h = lh + (self.tpadding + self.bpadding) * rtk.scale
    end
    self.lw, self.lh = lw, lh
    self.cw, self.ch = w, h
end

function rtk.Label:_draw(px, py, offx, offy, sx, sy, event)
    rtk.Widget._draw(self, px, py, offx, offy, sx, sy, event)
    local x, y = self.cx + offx, self.cy + offy

    if y + self.ch < 0 or y > rtk.h or self.ghost then
        -- Widget not viewable on viewport
        return
    end
    self:ondrawpre(offx, offy, event)
    self:_draw_bg(offx, offy, event)
    if self.halign == rtk.Widget.LEFT then
        gfx.x = x + self.lpadding
    elseif self.halign == rtk.Widget.CENTER then
        gfx.x = x + (self.cw - self.lw) / 2
    elseif self.halign == rtk.Widget.RIGHT then
        gfx.x = x + (self.cw - self.lw) - self.rpadding
    end
    -- TODO: support vertical alignment options.  Defaults to center.
    gfx.y = y + (self.ch - self.lh) / 2
    self:setcolor(self.color)
    rtk.set_font(self.font, self.fontsize, self.fontscale, self.fontflags)
    gfx.drawstr(self.vlabel, 0, x + self.cw, y + self.ch)
    self:ondraw(offx, offy, event)
end

-------------------------------------------------------------------------------------------------------------


rtk.ImageBox = class('rtk.ImageBox', rtk.Widget)
rtk.ImageBox.static._attr_filters.image = _filter_image

function rtk.ImageBox:initialize(attrs)
    rtk.Widget.initialize(self)
    self.image = nil
    self:setattrs(attrs)
end

-- ImageBoxes are passive widgets (by default)
-- function rtk.ImageBox:onmouseenter()
--     return false
-- end

function rtk.ImageBox:_reflow(boxx, boxy, boxw, boxh, fillw, fillh, viewport)
    self.cx, self.cy = self:_resolvepos(boxx, boxy, self.x, self.y, boxx, boxy)
    local w, h = self:_resolvesize(boxw, boxh, self.w, self.h, fillw and boxw or nil, fillh and boxh or nil)

    if self.image then
        w, h = w or self.image.width, h or self.image.height
    else
        w, h = 0, 0
    end
    self.cw, self.ch = w, h
end

function rtk.ImageBox:_draw(px, py, offx, offy, sx, sy, event)
    rtk.Widget._draw(self, px, py, offx, offy, sx, sy, event)
    local x, y = self.cx + offx, self.cy + offy

    if not self.image or y + self.ch < 0 or y > rtk.h or self.ghost then
        -- Widget not viewable on viewport
        return
    end

    self:ondrawpre(offx, offy, event)
    self:_draw_bg(offx, offy, event)

    if self.halign == rtk.Widget.LEFT then
        x = x + self.lpadding
    elseif self.halign == rtk.Widget.CENTER then
        x = x + (self.cw - self.image.width) / 2
    elseif self.halign == rtk.Widget.RIGHT then
        x = x + self.cw - self.rpadding
    end

    if self.valign == rtk.Widget.TOP then
        y = y + self.tpadding
    elseif self.valign == rtk.Widget.CENTER then
        y = y + (self.ch - self.image.height) / 2
    elseif self.valign == rtk.Widget.BOTTOM then
        y = y + self.ch - self.bpadding
    end

    self.image:draw(x, y, rtk.scale, nil, self.alpha)
    self:ondraw(offx, offy, event)
end

function rtk.ImageBox:onmousedown(event)
    return false
end


-------------------------------------------------------------------------------------------------------------

rtk.Heading = class('rtk.Heading', rtk.Label)

function rtk.Heading:initialize(attrs)
    rtk.Label.initialize(self)
    self.font, self.fontsize, self.fontflags = table.unpack(rtk.fonts.heading or rtk.fonts.default)
    self:setattrs(attrs)
end

-------------------------------------------------------------------------------------------------------------

rtk.OptionMenu = class('rtk.OptionMenu', rtk.Button)
rtk.OptionMenu.static._icon = nil
rtk.OptionMenu.static.SEPARATOR = 0

rtk.OptionMenu.static.ITEM_NORMAL = 0
rtk.OptionMenu.static.ITEM_CHECKED = 1
rtk.OptionMenu.static.ITEM_DISABLED = 2
rtk.OptionMenu.static.ITEM_HIDDEN = 4

rtk.OptionMenu.static.HIDE_LABEL = 32768

function rtk.OptionMenu:initialize(attrs)
    self.menu = {}
    self.selected = nil
    self.selected_id = nil
    rtk.Button.initialize(self, attrs)

    self._menustr = nil

    if not self.icon then
        if not rtk.OptionMenu._icon then
            -- Generate a new simple triangle icon for the button.
            local icon = rtk.Image():create(28, 18)
            self:setcolor(rtk.theme.text)
            rtk.push_dest(icon.id)
            gfx.triangle(12, 7,  20, 7,  16, 11)
            rtk.pop_dest()
            rtk.OptionMenu.static._icon = icon
        end
        self.icon = rtk.OptionMenu.static._icon
        self.flags = rtk.Button.ICON_RIGHT
    end
end

-- Return the size of the longest menu item
function rtk.OptionMenu:_reflow_get_label_size(boxw, boxh)
    rtk.set_font(self.font, self.fontsize, self.fontscale, 0)
    local w, h = 0, 0
    for _, item in ipairs(self._item_by_idx) do
        local label = item.buttonlabel or item.label
        item_w, item_h = gfx.measurestr(label)
        if item_w > w then
            w, h = item_w, item_h
        end
    end
    local lw, lh, lhs, vlabel = rtk.layout_gfx_string(self.label, false, true, boxw, boxh)
    -- Expand label width based on the longest item in the list, while still
    -- clamping it to the box size.
    lw = clamp(w, lw, boxw)
    return lw, lh, lhs, vlabel
end



function rtk.OptionMenu:setmenu(menu)
    return self:attr('menu', menu)
end

function rtk.OptionMenu:select(value, trigger)
    return self:attr('selected', value, trigger == nil or trigger)
end


function rtk.OptionMenu:onattr(attr, value, trigger)
    if attr == 'menu' then
        self._item_by_idx = {}
        self._idx_by_id = {}
        -- self._item_by_id = {}
        -- self._id_by_idx = {}
        self._menustr = self:_build_submenu(self.menu)
    elseif attr == 'selected' then
        -- First lookup by user id.
        local idx = self._idx_by_id[tostring(value)] or self._idx_by_id[value]
        if idx then
            -- Index exists by id.
            value = idx
        end
        local item = self._item_by_idx[value]
        if item then
            if self.flags & rtk.OptionMenu.HIDE_LABEL == 0 then
                self.label = item.buttonlabel or item.label
            end
            self.selected_id = item.id
            rtk.Button.onattr(self, attr, value, trigger)
            if trigger then
                self:onchange()
            end
        end
    else
        rtk.Button.onattr(self, attr, value, trigger)
    end
end

function rtk.OptionMenu:_build_submenu(submenu)
    local menustr = ''
    for n, menuitem in ipairs(submenu) do
        local label, id, flags, buttonlabel = nil, nil, nil, nil
        if type(menuitem) ~= 'table' then
            label = menuitem
        else
            label, id, flags, buttonlabel = table.unpack(menuitem)
        end
        if type(id) == 'table' then
            -- Append a special marker '#|' as a sentinel to indicate the end of the submenu.
            -- See onattr() above for rationale.
            menustr = menustr .. '>' .. label .. '|' .. self:_build_submenu(id) .. '<|'
        elseif label == rtk.OptionMenu.SEPARATOR then
            menustr = menustr .. '|'
        else
            self._item_by_idx[#self._item_by_idx + 1] = {label=label, id=id, flags=flags, buttonlabel=buttonlabel}
            -- Map this index to the user id (or a stringified version of the
            -- index if no user id is given)
            self._idx_by_id[tostring(id or #self._item_by_idx)] = #self._item_by_idx
            if not flags or flags & rtk.OptionMenu.ITEM_HIDDEN == 0 then
                if flags then
                    if flags & rtk.OptionMenu.ITEM_CHECKED ~= 0 then
                        label = '!' .. label
                    end
                    if flags & rtk.OptionMenu.ITEM_DISABLED ~= 0 then
                        label = '#' .. label
                    end
                end
                -- menustr = menustr .. (n == #submenu and '<' or '') .. label .. '|'
                menustr = menustr .. label .. '|'
            end
        end
    end
    return menustr
end

function rtk.OptionMenu:onmousedown(event)
    local function popup()
        gfx.x, gfx.y = self.sx + self.cx + self.last_offx, self.sy + self.cy + self.last_offy + self.ch
        local choice = gfx.showmenu(self._menustr)
        if choice > 0 then
            self:select(choice)
        end
    end
    -- Force a redraw and then defer opening the popup menu so we get a UI refresh with the
    -- button pressed before pening the menu, which is modal and blocks further redraws.
    rtk.Button.onmousedown(self, event)
    self:_draw(self.px, self.py, self.last_offx, self.last_offy, self.sx, self.sy, event)
    self:ondraw(self.last_offx, self.last_offy, event)
    if self._menustr ~= nil then
        reaper.defer(popup)
    end
    return true
end

function rtk.OptionMenu:onchange() end


-------------------------------------------------------------------------------------------------------------


rtk.Spacer = class('rtk.Spacer', rtk.Widget)

function rtk.Spacer:initialize(attrs)
    rtk.Widget.initialize(self)
    self:setattrs(attrs)
end


-------------------------------------------------------------------------------------------------------------
rtk.CheckBox = class('rtk.CheckBox', rtk.Button)
rtk.CheckBox.static.TYPE_TWO_STATE = 0
rtk.CheckBox.static.TYPE_THREE_STATE = 1
rtk.CheckBox.static.STATE_UNCHECKED = 0
rtk.CheckBox.static.STATE_CHECKED = 1
rtk.CheckBox.static.STATE_INDETERMINATE = 2
rtk.CheckBox.static._icon_unchecked = nil

function rtk.CheckBox:initialize(attrs)
    if rtk.CheckBox.static._icon_unchecked == nil then
        rtk.CheckBox.static._icon_unchecked = rtk.Image.make_icon('18-checkbox-unchecked')
        rtk.CheckBox.static._icon_checked = rtk.Image.make_icon('18-checkbox-checked')
        rtk.CheckBox.static._icon_intermediate = rtk.Image.make_icon('18-checkbox-intermediate')
        rtk.CheckBox.static._icon_hover = rtk.CheckBox.static._icon_unchecked:clone():accent()
    end
    self._value_map = {
        [rtk.CheckBox.static.STATE_UNCHECKED] = rtk.CheckBox.static._icon_unchecked,
        [rtk.CheckBox.static.STATE_CHECKED] = rtk.CheckBox.static._icon_checked,
        [rtk.CheckBox.static.STATE_INDETERMINATE] = rtk.CheckBox.static._icon_intermediate
    }
    local defaults = {
        flags = rtk.Button.FLAT_ICON | rtk.Button.FLAT_LABEL | rtk.Button.NO_HOVER,
        type = rtk.CheckBox.TYPE_TWO_STATE,
        value = rtk.CheckBox.STATE_UNCHECKED,
        icon = self._value_map[rtk.CheckBox.STATE_UNCHECKED],
        cursor =  rtk.mouse.cursors.pointer,
    }
    if attrs then
        table.merge(defaults, attrs)
    end
    rtk.Button.initialize(self, defaults)
    self:onattr('value', self.value)
end

function rtk.CheckBox:onclick(event)
    local value = self.value + 1
    if (self.type == rtk.CheckBox.TYPE_TWO_STATE and value > 1) or
       (self.type == rtk.CheckBox.TYPE_THREE_STATE and value > 2) then
        value = rtk.CheckBox.STATE_UNCHECKED
    end
    self:attr('value', value)
end

function rtk.CheckBox:_filter_attr(attr, value)
    if attr == 'value' then
        if value == false or value == nil then
            return rtk.CheckBox.STATE_UNCHECKED
        elseif value == true then
            return rtk.CheckBox.STATE_CHECKED
        end
    else
        return rtk.Button._filter_attr(self, attr, value)
    end
    return value
end

function rtk.CheckBox:onattr(attr, value, trigger)
    if attr == 'value' then
        self.icon = self._value_map[value] or self._value_map[0]
        if trigger then
            self:onchange()
        end
    end
end

function rtk.CheckBox:_draw_icon(x, y, hovering)
    rtk.Button._draw_icon(self, x, y, hovering)
    if hovering then
        rtk.CheckBox._icon_hover:draw(x, y, rtk.scale)
    end
end

function rtk.CheckBox:onchange()
end

-------------------------------------------------------------------------------------------------------------

return rtk
