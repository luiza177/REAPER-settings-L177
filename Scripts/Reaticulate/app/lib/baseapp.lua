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

local log = require 'lib.log'
local rtk = require 'lib.rtk'
require 'lib.utils'

BaseApp = class('BaseApp')
app = nil

function BaseApp:initialize(appid, title, basedir)
    if reaper.NamedCommandLookup('_SWS_TOGSELMASTER') == 0 then
        -- Sunk before we started.
        reaper.ShowMessageBox("Reaticulate requires the SWS extensions (www.sws-extension.org).\n\nAborting!",
                              "SWS extension missing", 0)
        return false
    end
    if not reaper.gmem_read then
        reaper.ShowMessageBox("Reaticulate requires Reaper v5.97 or later", "Reaper version too old", 0)
        return false
    end
    app = self
    Path.init(basedir)
    Path.imagedir = Path.join(Path.basedir, 'img')

    self.cmdserial = 0
    -- Callbacks indexed by cmd serial
    self.cmdcallbacks = {}
    -- Keep track of the number of in-flight requests, because Lua is retarded and
    -- #self.cmdcallbacks doesn't work.
    self.cmdpending = 0

    self.appid = appid
    self.title = title
    self.screens = {
        stack = {}
    }
    self.toolbar = {}

    if not self.config then
        -- Superclass didn't initialize config table, so do that now.
        self.config = {}
    end
    table.merge(self.config, {
        -- Initial dimensions
        x = 0,
        y = 0,
        w = 640,
        h = 480,
        dockstate = 0,
        scale = 1.0,
        bg = nil,
        borderless = false
    });
    self.viewport = nil

    rtk.ondock = function() self:handle_ondock() end
    rtk.onmove = function() self:handle_onmove() end
    rtk.onresize = function() self:handle_onresize() end
    rtk.onupdate = function() self:handle_onupdate() end
    rtk.onmousewheel = function(event) self:handle_onmousewheel(event) end
    rtk.onclose = function() self:handle_onclose() end
    rtk.onkeypresspost = function(event) self:handle_onkeypresspost(event) end

    self:get_config()

    -- Migration from boolean debug to logging level
    if self.config.debug_level == true or self.config.debug_level == 1 then
        self.config.debug_level = log.DEBUG
        self:save_config()
    elseif self.config.debug_level == false or self.config.debug_level == 0 then
        self.config.debug_level = log.ERROR
        self:save_config()
    end

    self:set_debug(self.config.debug_level or log.ERROR)
    self:set_theme()
    rtk.init(self.title, self.config.w, self.config.h, self.config.dockstate, self.config.x, self.config.y)
    self:build_frame()
end

function BaseApp:run()
    self:handle_onupdate()
    rtk.run()
end

function BaseApp:add_screen(name, package)
    local screen = require(package)
    self.screens[name] = screen
    if type(screen) == 'table' and screen.init then
        screen.init()
        screen.name = name
        if not screen.toolbar then
            -- Create a dummy toolbar for this screen to ensure app-wide toolbar
            -- remains pushed to the right.
            screen.toolbar = rtk.Spacer{h=0}
        end
        screen.toolbar:hide()
        -- Set min width for toolbar to at least make sure Back button is
        -- reachable.
        self.toolbar:insert(1, screen.toolbar, {expand=1, fillw=true, minw=50})
        screen.widget:hide()
    end
end

function BaseApp:show_screen(screen)
    screen = type(screen) == 'table' and screen or self.screens[screen]
    for _, s in ipairs(self.screens.stack) do
        s.widget:hide()
        if s.toolbar then
            s.toolbar:hide()
        end
    end
    if screen then
        log.info("baseapp: showing screen %s", screen.name)
        screen.update()
        screen.widget:show()
        if self.viewport then
            self.viewport:attr('child', screen.widget)
        else
            self.frame:replace(self.frame.content_position, screen.widget, {
                expand=1,
                fillw=true,
                fillh=true,
                minw=screen.minw
            })
        end
        if screen.toolbar then
            screen.toolbar:show()
        end
    end
    self:set_statusbar(nil)
end

function BaseApp:push_screen(screen)
    screen = type(screen) == 'table' and screen or self.screens[screen]
    if screen and #self.screens.stack > 0 and self:current_screen() ~= screen then
        self:show_screen(screen)
        self.screens.stack[#self.screens.stack+1] = screen
    end
end

function BaseApp:pop_screen()
    if #self.screens.stack > 1 then
        self:show_screen(self.screens.stack[#self.screens.stack-1])
        table.remove(self.screens.stack)
        return true
    else
        return false
    end
end

function BaseApp:replace_screen(screen)
    screen = type(screen) == 'table' and screen or self.screens[screen]
    self:show_screen(screen)
    local idx = #self.screens.stack
    if idx == 0 then
        idx = 1
    end
    self.screens.stack[idx] = screen
end

function BaseApp:current_screen()
    return self.screens.stack[#self.screens.stack]
end


-- App-wide utility functions
local function _swallow_event(self, event)
    event:set_handled(self)
    return false
end

function BaseApp:make_button(icon, label, textured, attrs)
    local button = nil
    if label then
        flags = textured and 0 or (rtk.Button.FLAT_ICON | rtk.Button.FLAT_LABEL | rtk.Button.NO_SEPARATOR)
        button = rtk.Button{icon=icon, label=label, flags=flags,
                            tpadding=5, bpadding=5, lpadding=5, rpadding=10}
    else
        flags = textured and 0 or (rtk.Button.FLAT_ICON | rtk.Button.NO_SEPARATOR)
        button = rtk.Button{icon=icon, flags=flags,
                            tpadding=5, bpadding=5, lpadding=5, rpadding=5}
    end
    button:setattrs(attrs)
    -- Default drag handler prevents lower-zindex widgets from handling drags.
    -- So if the user drags the button, it prevents drag handlers for widgets
    -- underneath from triggering.
    button.ondragstart = _swallow_event
    return button
end

function BaseApp:get_icon_path(name)

end

function BaseApp:fatal_error(msg)
    msg = msg .. "\n\nReaticulate must now exit."
    reaper.ShowMessageBox(msg, "Reaticulate: fatal error", 0)
    rtk.quit()
end



function BaseApp:get_config()
    if reaper.HasExtState(self.appid, "config") then
        local state = reaper.GetExtState(self.appid, "config")
        local config = table.fromstring(state)
        -- Merge stored config into runtime config
        for k, v in pairs(config) do
            self.config[k] = v
        end
    end
end

function BaseApp:save_config()
    reaper.SetExtState(self.appid, "config", table.tostring(self.config), true)
end

function BaseApp:set_debug(level)
    self.config.debug_level = level
    self:save_config()
    log.level = level or log.ERROR
    log.info("baseapp: Reaticulate log level is %s", log.level_name())
end

function BaseApp:handle_ondock()
    self.config.dockstate = rtk.dockstate
    if (rtk.dockstate or 0) & 0x01 ~= 0 then
        self.config.last_dockstate = rtk.dockstate
    end
    if self.toolbar.pin then
        self.toolbar.pin:hide()
        self.toolbar.unpin:hide()
        self.resize_grip:hide()
    end
    if rtk.hwnd and rtk.has_js_reascript_api then
        log.info('baseapp: js_ReaScriptAPI extension is available')
        if rtk.dockstate == 0 then
            if reaper.JS_Window_SetStyle then
                if self.config.borderless then
                    reaper.JS_Window_SetStyle(rtk.hwnd, 'POPUP')
                    -- Resize to original dimensions to account for the lack of window border.
                    reaper.JS_Window_Resize(rtk.hwnd, rtk.w, rtk.h)
                    self:_set_window_pinned(self.config.pinned)
                    self.resize_grip:show()
                else
                    reaper.JS_Window_SetStyle(rtk.hwnd, 'CAPTION,SIZEBOX,SYSMENU')
                    reaper.JS_Window_SetZOrder(rtk.hwnd, 'NOTOPMOST')
                    -- XXX: there's a bug on Windows: https://forum.cockos.com/showthread.php?p=2195902#post2195902
                    reaper.JS_Window_AttachTopmostPin(rtk.hwnd)
                end
            else
                reaper.JS_Window_AttachTopmostPin(rtk.hwnd)
            end
        end
    end
    self:save_config()
end

function BaseApp:handle_onresize()
    -- Only save dimensions when not docked.
    if (rtk.dockstate or 0) & 0x01 == 0 then
        self.config.x, self.config.y = rtk.x, rtk.y
        self.config.w, self.config.h = rtk.w, rtk.h
        self:save_config()
    end
end

function BaseApp:handle_onmove(last_x, last_y)
    self:handle_onresize()
end

function BaseApp:handle_onmousewheel(event)
    if event.ctrl then
        -- ctrl-wheel scaling
        if event.wheel < 0 then
            rtk.scale = rtk.scale + 0.05
        else
            rtk.scale = rtk.scale - 0.05
        end
        self:set_statusbar(string.format('Zoom UI to %.02fx', rtk.scale))
        self.config.scale = rtk.scale
        self:save_config()
        rtk.queue_reflow()
        event.wheel = 0
    end
end

function BaseApp:set_theme()
    local bg = self.config.bg
    if not bg or type(bg) ~= 'string' or #bg <= 1 then
        bg = rtk.get_reaper_theme_bg()
    end
    -- Determine from theme background color if we should use the light or dark theme.
    local luma = color2luma(bg)
    log.debug("baseapp: theme bg is %s", bg)
    -- bg = '#252525'
    if luma > 0.7 then
        rtk.set_theme('light', Path.join(Path.imagedir, 'icons-dark'), {window_bg=bg})
    else
        rtk.set_theme('dark', Path.join(Path.imagedir, 'icons-light'), {window_bg=bg})
    end

end

function BaseApp:set_statusbar(label)
    if label then
        self.statusbar.label:attr('label', label)
    else
        self.statusbar.label:attr('label', " ")
    end
end

function BaseApp:build_frame()
    local toolbar = rtk.HBox{spacing=0, bg=rtk.theme.window_bg}
    self.toolbar = toolbar

    self.frame = rtk.VBox{position=rtk.Widget.FIXED, z=100}
    self.frame:add(toolbar, {minw=150})

    -- Add a placeholder widget that screens will replace.
    self.frame:add(rtk.VBox.FLEXSPACE)
    self.frame.content_position = #self.frame.children

    self.statusbar = rtk.HBox{
        bg=rtk.theme.window_bg,
        lpadding=10,
        tpadding=5,
        bpadding=5,
        rpadding=10,
        z=110
    }
    self.statusbar.label = self.statusbar:add(rtk.Label{color=rtk.theme.text_faded}, {expand=1})
    self.frame:add(self.statusbar, {fillw=true})

    rtk.widget:add(self.frame)
    self:set_statusbar('')
    if reaper.JS_Window_SetStyle then
        self:_setup_borderless_handlers()
    end
end

function BaseApp:_set_window_pinned(pinned)
    reaper.JS_Window_SetZOrder(rtk.hwnd, pinned and 'TOPMOST' or 'NOTOPMOST')
    self.toolbar.pin:attr('visible', not pinned)
    self.toolbar.unpin:attr('visible', pinned)
    self.config.pinned = pinned
    self:save_config()
end

function BaseApp:_setup_borderless_handlers()
    self.toolbar.pin = self.toolbar:add(self:make_button('18-pin_off'), {rpadding=15})
    self.toolbar.unpin = self.toolbar:add(self:make_button('18-pin_on'), {rpadding=15})
    self.toolbar.pin.onclick = function() self:_set_window_pinned(true) end
    self.toolbar.unpin.onclick = function() self:_set_window_pinned(false) end
    self:_set_window_pinned(false)

    self.toolbar.ondragstart = function(self, event)
        if reaper.JS_Window_Move and rtk.dockstate == 0 and app.config.borderless then
            local _, wx, wy, _, _ = reaper.JS_Window_GetClientRect(rtk.hwnd)
            self._drag_start_ex, self._drag_start_ey = event.x, event.y
            self._drag_start_wx, self._drag_start_wy = wx, wy
            self._drag_start_ww, self._drag_start_wh = rtk.w, rtk.h
            return true
        else
            -- Prevent ondragmove from firing.
            return false
        end
    end
    self.toolbar.ondragmousemove = function(self, event)
        local _, wx, wy, _, _ = reaper.JS_Window_GetClientRect(rtk.hwnd)
        local x, y = wx + (event.x - self._drag_start_ex)
        if rtk.os.mac then
            y = (wy - self._drag_start_wh) - (event.y - self._drag_start_ey)
        else
            y = wy + (event.y - self._drag_start_ey)
        end
        reaper.JS_Window_Move(rtk.hwnd, x, y)
    end

    local imgbox = rtk.ImageBox{image='24-resize_bottom_right', z=200, cursor=rtk.mouse.cursors.size_nw_se, alpha=0.4}
    imgbox.onmouseenter = function(self)
        if app.config.borderless then
            self:animate('alpha', 1, 0.1)
            return true
        end
    end
    imgbox.onmouseleave = function(self, event)
        if app.config.borderless then
            self:animate('alpha', 0.4, 0.25)
        end
    end
    imgbox.ondragstart = self.toolbar.ondragstart
    imgbox.ondragmousemove = function(self, event)
        local x = event.x - self._drag_start_ex
        local y = event.y - self._drag_start_ey
        reaper.JS_Window_Resize(rtk.hwnd, self._drag_start_ww + x, self._drag_start_wh + y)
        if rtk.os.mac then
            reaper.JS_Window_Move(rtk.hwnd, self._drag_start_wx, self._drag_start_wy - self._drag_start_wh - y)
        end
    end
    self.resize_grip = imgbox
    rtk.widget:add(imgbox, {valign='bottom', halign='right'})
end

function BaseApp:handle_onupdate()
    self:check_commands()
end

function BaseApp:timeout_command_callbacks()
    now = os.clock()
    for serial in pairs(self.cmdcallbacks) do
        local expires, cb = table.unpack(self.cmdcallbacks[serial])
        if now > expires then
            cb(nil)
            self.cmdcallbacks[serial] = nil
            self.cmdpending = self.cmdpending - 1
        end
    end
end

-- Sends a command to the given appid.  The command can take arbitrarily
-- many arguments.
--
-- If the last argument is a function and a passed is a function, then it
-- the remote command will request a response and the function will be
-- invoked upon reply.  The callback will be passed an argument containing
-- the remote response.  If the argument is nil, it means the remote end
-- did not respond before the timeout.
--
-- The timeout defaults to 2 seconds, but it can be overriden by passing
-- another argument after the callback.
function BaseApp:send_command(appid, cmd, ...)
    local cmdlist = reaper.GetExtState(appid, "command")
    if cmdlist then
        if cmdlist:len() > 200 then
            -- Too many queued commands.  Target appid not responding.  Truncate the existing
            -- list.
            log.warn("baseapp: %s not responding", appid)
            cmdlist = ''
        else
            cmdlist = cmdlist .. ' '
        end
    else
        cmdlist = ''
    end
    local args = {...}
    local callback = nil
    local timeout = 2

    if #args >= 1 and type(args[#args]) == 'function' then
        callback = table.remove(args, #args)
    elseif #args >= 2 and type(args[#args - 1]) == 'function' then
        timeout = table.remove(args, #args)
        callback = table.remove(args, #args)
    end
    if #args == 0 then
        -- Protocol requires _some_ argument, so just make a dummy one
        args = {0}
    end
    if callback then
        self.cmdserial = self.cmdserial + 1
        local serial = tostring(self.cmdserial)
        self.cmdcallbacks[serial] = {os.clock() + timeout, callback}
        self.cmdpending = self.cmdpending + 1
        cmd = string.format('?%s:%s,%s', cmd, self.appid, serial)
    end
    local joined = table.concat(args, ',')
    reaper.SetExtState(appid, "command", cmdlist .. cmd .. '=' .. joined, false)
end



function BaseApp:handle_command(cmd, arg)
    if cmd == 'ping' then
        reaper.SetExtState(self.appid, "pong", arg, false)
        return arg
    elseif cmd == 'quit' then
        rtk.quit()
    end
end


function BaseApp:check_commands()
    if self.cmdpending  > 0 then
        -- We have pending requests.  Clean up those that have timed out.
        self:timeout_command_callbacks()
    end
    if reaper.HasExtState(self.appid, "command") then
        local val = reaper.GetExtState(self.appid, "command")
        reaper.DeleteExtState(self.appid, "command", false)
        for cmd, arg in val:gmatch('(%S+)=([^"]%S*)') do
            if cmd:starts('?') then
                -- This request expects an async reply.  Command will be in the form:
                -- ?cmd:appid,serial
                local cmd, return_appid, serial = cmd:match("%?([^:]+):([^,]+),(.*)")
                local response = self:handle_command(cmd, arg)
                self:send_command(return_appid, '!' .. serial, tostring(response))
            elseif cmd:starts('!') then
                -- This is an async reply.  Command is in the form: !serial
                local serial = cmd:match("!(.*)")
                local cbinfo = self.cmdcallbacks[serial]
                if cbinfo then
                    self.cmdcallbacks[serial][2](arg)
                    self.cmdcallbacks[serial] = nil
                    self.cmdpending = self.cmdpending - 1
                else
                    log.error("baseapp: %s received reply to unknown request %s", self.appid, serial)
                end
            else
                self:handle_command(cmd, arg)
            end
        end
    end

end

function BaseApp:handle_onclose()
    rtk.quit()
end

function BaseApp:handle_onkeypresspost(event)
end

return BaseApp
