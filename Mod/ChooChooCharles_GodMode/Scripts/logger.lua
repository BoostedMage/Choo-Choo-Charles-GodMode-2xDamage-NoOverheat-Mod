-- Bounded batched diagnostic output. All methods run on the game thread.
-- append() normally performs no filesystem I/O; main.lua calls flush() once
-- per second and after F9. No file handle is held between calls.
local Logger = {}
local DEFAULT_FILES = {"CCC_Mod_Status.log", "CCC_Reflection.log", "CCC_Events.log"}
local DEFAULT_LIMIT = 8 * 1024 * 1024
local DEFAULT_PENDING = 256 * 1024

function Logger.new(deps)
    assert(type(deps) == "table" and type(deps.root) == "string", "logger root is required")
    local open = deps.open or io.open
    local remove = deps.remove or os.remove
    local rename = deps.rename or os.rename
    local date = deps.date or os.date
    local report = deps.report or function() end
    local limit = deps.limit_bytes or DEFAULT_LIMIT
    local pending_limit = deps.pending_limit_bytes or DEFAULT_PENDING
    assert(type(limit) == "number" and limit >= 256, "logger file budget must be at least256bytes")
    assert(type(pending_limit) == "number" and pending_limit >= 256, "logger queue budget must be at least256bytes")
    local cap_line = "LOG SIZE LIMIT REACHED (" .. (limit == DEFAULT_LIMIT and "8 MiB" or tostring(limit) .. " bytes")
        .. "); earlier complete events retained.\n"
    local files, order = {}, {}
    local self = {}

    local function warn(file, message)
        if file.last_error == message then return end
        file.last_error = message
        pcall(report, "Cannot write " .. file.name .. ": " .. message)
    end

    local function disk_size(handle)
        local ok, size = pcall(function() return handle:seek("end") end)
        return ok and type(size) == "number" and size >= 0 and size or nil
    end

    for _, name in ipairs(deps.files or DEFAULT_FILES) do
        assert(type(name) == "string" and name:match("^[%w_.%-]+%.log$") and not files[name],
            "logger filenames must be unique simple .log names")
        local file = {name=name, path=deps.root .. "/" .. name, queue={}, pending_bytes=0,
            max_pending_bytes=0, used_bytes=0, lines=0, bytes=0, accepted_lines=0,
            submitted_lines=0, flushes=0, file_opens=0, failures=0,
            dropped_lines=0, dropped_unreported=0, suppressed_lines=0,
            capped=false, cap_needed=false, blocked=false, last_error=nil}
        files[name], order[#order + 1] = file, file
        local ok, old = pcall(open, file.path, "rb")
        if ok and old then
            file.used_bytes = disk_size(old) or 0
            pcall(function() old:close() end)
            local previous = file.path:gsub("%.log$", ".previous.log")
            pcall(remove, previous)
            local renamed, result, why = pcall(rename, file.path, previous)
            if renamed and result then
                file.used_bytes = 0
            else
                warn(file, "rotation failed; retaining the existing file: " .. tostring(why or result))
            end
        end
        if file.used_bytes >= limit - #cap_line then
            file.capped, file.cap_needed = true, file.used_bytes + #cap_line <= limit
        end
    end

    local function reject(file, reason)
        file.dropped_lines = file.dropped_lines + 1
        file.dropped_unreported = file.dropped_unreported + 1
        if not file.drop_reported then
            file.drop_reported = true
            pcall(report, "Diagnostic queue for " .. file.name .. " is bounded: " .. reason
                .. "; new lines are being counted as dropped until output recovers.")
        end
        return false, reason
    end

    local function flush_file(file, explicit)
        if file.pending_bytes == 0 and not file.cap_needed and file.dropped_unreported == 0 then return true end
        -- After an I/O failure, a large reflection dump must not retry an open
        -- for every additional line. Only the next scheduled/F9 flush retries.
        if file.blocked and not explicit then return false end
        file.file_opens = file.file_opens + 1
        -- Binary append avoids Windows text-mode CRLF expansion so the byte
        -- budget and actual on-disk length stay identical on the target OS.
        local opened, handle, open_error = pcall(open, file.path, "ab")
        if not opened or not handle then
            file.failures, file.blocked = file.failures + 1, true
            warn(file, tostring(open_error or handle or "open failed") .. "; batch retained for retry")
            return false
        end

        -- Re-read the actual end after a failed/partial write or an external
        -- change. This prevents retry duplication from bypassing the file cap.
        file.used_bytes = disk_size(handle) or file.used_bytes
        local budget = math.max(0, limit - file.used_bytes - #cap_line)
        while file.pending_bytes > budget and #file.queue > 0 do
            local last = table.remove(file.queue)
            file.pending_bytes = file.pending_bytes - #last
            file.suppressed_lines = file.suppressed_lines + 1
            file.capped, file.cap_needed = true, true
        end
        local payload, records = table.concat(file.queue), #file.queue
        local drop_notice = ""
        if file.dropped_unreported > 0 then
            drop_notice = tostring(date("!%Y-%m-%dT%H:%M:%SZ ")) .. "LOGGER DROPPED "
                .. tostring(file.dropped_unreported) .. " new lines while the bounded queue was unavailable.\n"
            if #payload + #drop_notice > budget then
                drop_notice = ""
                file.capped, file.cap_needed = true, true
            end
        end
        if drop_notice ~= "" then payload, records = payload .. drop_notice, records + 1 end
        if file.cap_needed and file.used_bytes + #payload + #cap_line <= limit then
            payload, records = payload .. cap_line, records + 1
        end

        local wrote, result, write_error = pcall(function() return handle:write(payload) end)
        local closed, close_result, close_error = pcall(function() return handle:close() end)
        if not wrote or not result or not closed or not close_result then
            file.failures, file.blocked = file.failures + 1, true
            -- A failed close can mean the preceding write was only partially
            -- flushed. Keep the whole batch. A retry may repeat some lines;
            -- the warning makes that uncertainty visible instead of losing it.
            warn(file, tostring(write_error or (not wrote and result) or close_error
                or (not closed and close_result) or "write/close failed")
                .. "; batch retained for retry; a partial write may repeat earlier lines")
            return false
        end
        file.used_bytes = file.used_bytes + #payload
        file.bytes, file.lines = file.bytes + #payload, file.lines + records
        file.flushes = file.flushes + 1
        file.queue, file.pending_bytes = {}, 0
        file.cap_needed, file.blocked, file.last_error = false, false, nil
        if drop_notice ~= "" then
            file.dropped_unreported, file.drop_reported = 0, false
        elseif file.capped or file.used_bytes >= limit - #cap_line then
            -- Counts stay in snapshot() when the file is too full for a notice.
            file.dropped_unreported = 0
        end
        return true
    end

    function self:append(name, text)
        local file = files[name]
        if not file then return false, "unregistered log filename" end
        file.submitted_lines = file.submitted_lines + 1
        if file.capped then file.suppressed_lines = file.suppressed_lines + 1; return false, "file size limit" end
        local line = tostring(date("!%Y-%m-%dT%H:%M:%SZ ")) .. tostring(text) .. "\n"
        if #line > pending_limit then return reject(file, "one line exceeds the pending-byte budget") end
        if file.used_bytes + file.pending_bytes + #line > limit - #cap_line then
            file.capped, file.cap_needed = true, true
            file.suppressed_lines = file.suppressed_lines + 1
            return false, "file size limit"
        end
        if file.pending_bytes + #line > pending_limit then flush_file(file, false) end
        if file.pending_bytes + #line > pending_limit then return reject(file, "pending-byte budget exhausted after an I/O failure") end
        if file.capped then file.suppressed_lines = file.suppressed_lines + 1; return false, "file size limit" end
        if file.used_bytes + file.pending_bytes + #line > limit - #cap_line then
            file.capped, file.cap_needed = true, true
            file.suppressed_lines = file.suppressed_lines + 1
            return false, "file size limit"
        end
        file.queue[#file.queue + 1] = line
        file.pending_bytes = file.pending_bytes + #line
        file.max_pending_bytes = math.max(file.max_pending_bytes, file.pending_bytes)
        file.accepted_lines = file.accepted_lines + 1
        return true
    end

    function self:flush()
        local ok = true
        for _, file in ipairs(order) do
            if not flush_file(file, true) then ok = false end
        end
        return ok
    end

    function self:snapshot()
        local result = {lines=0, bytes=0, submitted_lines=0, accepted_lines=0,
            flushes=0, file_opens=0, failures=0, dropped_lines=0, suppressed_lines=0,
            pending_bytes=0, max_pending_bytes=0, files={}}
        for _, file in ipairs(order) do
            local detail = {capped=file.capped, blocked=file.blocked, used_bytes=file.used_bytes}
            for key, value in pairs(result) do
                if type(value) == "number" then
                    detail[key] = file[key]
                    result[key] = result[key] + file[key]
                end
            end
            result.files[file.name] = detail
        end
        return result
    end

    return self
end

return Logger
