local Promise = require('orgmode.utils.promise')

local M = {}
M.test = {}

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

local function set_end_time(headline, idlemins)
    local logbook = headline.logbook
    local last_clock = logbook.items[1]
    --print("clock", vim.inspect(last_clock))
    --print("idlemins", idlemins)
    local start_time = last_clock.start_time
    local line_nr = start_time.range.start_line
    last_clock.end_time = last_clock.end_time:subtract({ min = idlemins })
    last_clock.duration = orgduration.from_seconds(
        last_clock.end_time.timestamp - last_clock.start_time.timestamp
    )
    print(line_nr)
    --local clock_text = duration:to_string('HH:MM')
    --print(vim.inspect(clock_text))
    --print(vim.inspect(last_clock))
    target = headline.file
    if target == vim.fn.expand("%") then
        target = vim.fn.expand("%:p")
    end
    orgfiles.update_file(target, function()
        print("Starting thing!")
        local line = vim.fn.getline(line_nr):gsub('%-%-.*$', '')
        print(line)
        local line = string.format(
            '%s--%s',
            line,
            last_clock.end_time:to_wrapped_string()
        )
        print(line)
        vim.api.nvim_call_function('setline', { line_nr, line })

        logbook:recalculate_estimate(line_nr)
        return "Yay"
    end):next(function(result) print("Result", result) end)
end
M.test.set_end_time = set_end_time

local function dialog_action(headline, action, idlemins, window)
    print(headline.title, headline.file, action, idlemins, window)
    orgfiles.update_file(headline.file, function()
        local logbook = headline.logbook
        if action == "k" then
        elseif action == "K" then
            logbook:clock_out()
        elseif action == "s" then
            logbook:clock_out()
            set_end_time(headline, idlemins)
            logbook:add_clock_in()
        elseif action == "S" then
            logbook:clock_out()
            set_end_time(headline, idlemins)
        elseif action == "C" then
            logbook:cancel_active_clock()
        elseif action == "q" then
            -- just close, same as k
        end
    end)
    -- TODO: Refresh agenda
    M.last_activity = vim.fn.reltime()
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

-- Returns time since last activity in seconds
local function get_idle_native()
    return math.floor(vim.fn.reltimefloat(vim.fn.reltime(M.last_activity)))
end

local function show_dialog(headline, idletime)
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
        "You just returned from being idle "..math.floor(idletime+0.5).." minutes.",
        "\t- (k)eep the clocked-in time and stay clocked-in",
        "\t- (K)eep the clocked-in time and clock out",
        "\t- (s)ubtract the time and stay clocked-in",
        "\t- (S)ubtract the time and clock out",
        "\t- (C)ancel the clock altogether",
    })

    add_action = function(key, desc, callback)
        print(key, desc, callback)
        if not callback then
            callback = function()
                dialog_action(headline, key, idletime, win)
            end
        end
        vim.keymap.set("n", key, callback, {
            buffer = buf,
            silent = true,
            noremap = true,
            desc = desc
        })
    end

    add_action("k", "Keep clock")
    add_action("K", "Keep clock and clock out")
    add_action("s", "Subtract from clock")
    add_action("S", "Subtract from clock and clock out")
    add_action("C", "Reset clock completely")
    add_action("q", "Close window and keep clock")

    -- TODO: This focusing isn't working
    vim.api.nvim_set_current_win(win)
    vim.cmd("stopinsert")
    -- vim.ui.input({
    --     prompt = ""
    -- }, {})
end

local function handle_return()
    M.inactive = false
    if not M.in_dialog then
        local idle_secs = get_idle_native()
        local idle_mins = idle_secs/60
        local last_seen = vim.fn.localtime() - idle_secs
        vim.notify("You came back! I last saw you "..math.floor(idle_mins+0.5).." minutes ago ("..vim.fn.strftime("%a %H:%M", last_seen)..")")

        local headline = orgfiles.get_clocked_headline()
        if headline then
            print("Showing dialog...")
            M.in_dialog = true
            show_dialog(headline, idle_mins)
        else
            print("Not clocked in, ignoring")
        end
    end
    M.last_activity = vim.fn.reltime()
end

M.defaults = {
    timeout = 2, -- seconds
    idletime = 10, -- minutes
    callback = function()
        if M.in_dialog then return end

        if M.pending_activity then
            M.last_activity = vim.fn.reltime()
            M.pending_activity = false
        elseif not M.inactive then
            local idle_secs = get_idle_native()
            local idle_mins = idle_secs/60
            if idle_mins and idle_mins > M.config.idletime then
                print("Idle for "..idle_mins.." minutes, marking inactive")
                M.inactive = true
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
    vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI", "FocusGained", "CmdlineChanged"}, {
        group = M.augroup,
        pattern = "*",
        callback = function(ev)
            if M.inactive then
                handle_return()
            else
                M.pending_activity = true
            end
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
