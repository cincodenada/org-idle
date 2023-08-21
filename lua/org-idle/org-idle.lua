local Promise = require('orgmode.utils.promise')

local M = {}

local org_status, org                  = pcall(require, "orgmode")
local org_files_status, orgfiles       = pcall(require, "orgmode.parser.files")
local org_duration_status, orgduration = pcall(require, "orgmode.objects.duration")

if not (org_status and org_files_status and org_duration_status) then
    return
end

--if not vim.fn.executable("xprintidle") then
--    vim.notify("xprintidle not installed, org-idle depends on it!", vim.log.level.WARN)
--    return
--end

local function get_agenda_buf()
    local bufs = vim.fn.getbufinfo()
    for idx, buf in pairs(bufs) do
       if buf.variables.org_agenda_type == 'agenda' then
           return buf.bufnr
       end
    end
end

local function callback(logbook, action, duration, window)
    local agenda = require("orgmode.agenda")
    local active_clock = logbook.items[1]
    local agendabuf = get_agenda_buf()
    print(logbook, action, duration, window, agendabuf)
    print("logbook", vim.inspect(logbook), vim.inspect(active_clock))
    if action == "k" then
    elseif action == "K" then
        agenda:clock_out()
    elseif action == "s" then
        local result = agenda:clock_out()
        if result then
            result.next(function()
                active_clock.end_time = active_clock.end_time:subtract({ orgduration.from_seconds(duration) })
                agenda:clock_in()
                -- logbook:recalculate_estimate()
            end)
        end
    elseif action == "S" then
        local result = Promise.resolve(agenda:clock_out()):next(function(_)
            if _ then print("result", vim.inspect(_)) end
            print(vim.inspect(duration), vim.inspect(orgduration.from_seconds(duration)))
            active_clock.end_time = active_clock.end_time:subtract({ orgduration.from_seconds(duration) })
            agenda:clock_in()
            logbook:recalculate_estimate(1)
            active_clock.end_time = active_clock.end_time:subtract({ orgduration.from_seconds(duration) })
        end)
    elseif action == "C" then
        agenda:clock_cancel() -- .next(function()
            -- logbook:cancel_active_clock()
        --end)
    end
    M.in_dialog = false
    vim.api.nvim_win_close(window, true)
end

local function get_idle_x()
    local proc = io.popen("xprintidle", "r")
    if proc then
        local idletime = tonumber(proc:read()) / 1000
        proc:close()
        return idletime
    end
    return false
end

local function get_idle_native()
    return vim.fn.reltimefloat(vim.fn.reltime(M.last_activity))
end

local function handle_return(idletime)
    vim.notify("You came back!")
    local headline = orgfiles.get_clocked_headline()
    if headline then
        local buf = vim.api.nvim_create_buf(false, true)
        local win = vim.api.nvim_open_win(buf, false, {
            relative = "editor",
            width = 60,
            height = 20,
            row = 0.25,
            col = 0.25,
            border = "rounded",
        })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "You just returned from being idle "..math.floor(idletime).." minutes.",
            "\t- (k)eep the clocked-in time and stay clocked-in",
            "\t- (K)eep the clocked-in time and clock out",
            "\t- (s)ubtract the time and stay clocked-in",
            "\t- (S)ubtract the time and clock out",
            "\t- (C)ancel the clock altogether",
        })
        vim.cmd("stopinsert")

        local logbook = headline.logbook

        vim.keymap.set("n", "k", function() callback(logbook, "k", idletime) end,
            { buffer = buf, silent = true, noremap = true, desc = "Keep clock" })
        vim.keymap.set("n", "K", function() callback(logbook, "K", idletime, win) end,
            { buffer = buf, silent = true, noremap = true, desc = "Keep clock and clock out" })
        vim.keymap.set("n", "s", function() callback(logbook, "s", idletime, win) end,
            { buffer = buf, silent = true, noremap = true, desc = "Subtract from clock" })
        vim.keymap.set("n", "S", function() callback(logbook, "S", idletime, win) end,
            { buffer = buf, silent = true, noremap = true, desc = "Subtract from clock and clock out" })
        vim.keymap.set("n", "C", function() callback(logbook, "C", idletime, win) end,
            { buffer = buf, silent = true, noremap = true, desc = "Reset clock completely" })
        vim.keymap.set("n", "q", "<CMD>close<CR>",
            { buffer = buf, silent = true, noremap = true, desc = "Close window and keep clock" })
        vim.api.nvim_set_current_win(win)
        -- vim.ui.input({
        --     prompt = ""
        -- }, {})
    end
end

M.test = function(idletime)
    handle_return(idletime)
end

M.defaults = {
    timeout = 2,
    idletime = 10,
    callback = function()
        local idletime = get_idle_native()
        if idletime then
            if M.idle then
                if M.active then
                    M.idle = false
                    M.last_activity = vim.fn.reltime()
                    if not M.in_dialog then
                        M.in_dialog = true
                        handle_return(idletime)
                    end
                end
            else
                if idletime > M.config.idletime then
                    M.idle = true
                end
            end
        end
    end
}

function M.setup(user_config)
    user_config = user_config or {}
    M.config = vim.tbl_deep_extend("force", M.defaults, user_config)

    -- Set up activity watcher
    M.last_activity = vim.fn.reltime()
    M.augroup = vim.api.nvim_create_augroup("OrgIdle", {})
    vim.api.nvim_create_autocmd({"CursorHold"}, {
        group = M.augroup,
        pattern = "*",
        callback = function(ev)
            M.last_activity = vim.fn.reltime()
        end
    })
    vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {
        group = M.augroup,
        pattern = "*",
        callback = function(ev)
            M.active = true
        end
    })

    -- Set up timer callback
    if M.timer then
        M.timer:stop()
        M.timer:close()
    end
    M.timer = vim.loop.new_timer()
    if M.timer then
        M.timer:start(M.config.timeout * 1000, M.config.timeout * 1000, vim.schedule_wrap(M.config.callback))
    else
        vim.notify("Timer creation resulted in error!", vim.log.levels.ERROR)
    end
end

function M.stop()
    if M.timer then
        M.timer:stop()
        M.timer:close()
    end
end

return M
