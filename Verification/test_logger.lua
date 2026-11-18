-- Real Lua file I/O checks plus an injected failure boundary. No Unreal/game.
local scripts = assert(os.getenv("CCC_MOD_SCRIPTS"))
local Logger = dofile(scripts .. "/logger.lua")
local root = assert(os.getenv("CCC_TEST_ROOT")) .. "/Scripts"
local count = 0
local function check(value, message) assert(value, message); count = count + 1 end
local function write(path, text)
    local f = assert(io.open(path, "wb")); assert(f:write(text)); assert(f:close())
end
local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local text = f:read("*a"); f:close(); return text
end
local stamp = function() return "2026-11-18T17:00:00Z " end
write(root .. "/CCC_Mod_Status.log", "prior session\n")
write(root .. "/CCC_Mod_Status.previous.log", "older session\n")
local reports = {}
local log = Logger.new({root=root,date=stamp,report=function(s) reports[#reports+1]=s end})
check(read(root .. "/CCC_Mod_Status.previous.log") == "prior session\n", "rotation preserves immediately previous session")
check(read(root .. "/CCC_Mod_Status.log") == nil, "current session starts empty without holding a handle")
for i=1,1000 do check(log:append("CCC_Mod_Status.log", "event " .. i), "normal line queued") end
check(read(root .. "/CCC_Mod_Status.log") == nil, "1000 queued lines cause no per-line writes")
check(log:snapshot().file_opens == 0 and log:snapshot().pending_bytes > 0, "write opens stay zero before flush")
log:append("CCC_Reflection.log", "reflect one")
log:append("CCC_Events.log", "damage one")
check(log:flush(), "batched flush succeeds")
local text = read(root .. "/CCC_Mod_Status.log")
check(text:sub(1,#(stamp() .. "event 1\n")) == stamp() .. "event 1\n", "timestamp retained on first line")
check(text:find(stamp() .. "event 999\n" .. stamp() .. "event 1000\n",1,true), "queued order retained")
local stats = log:snapshot()
check(stats.file_opens == 3 and stats.flushes == 3 and stats.lines == 1002, "one open/write/close batch per nonempty file")
check(stats.pending_bytes == 0 and stats.dropped_lines == 0, "successful batches release all pending memory without loss")
check(log:flush() and log:snapshot().file_opens == 3, "empty flushes never open files")
check(not log:append("../unrelated.log","bad") and read(root .. "/unrelated.log") == nil, "unknown filename cannot escape registered logs")
check(#reports == 0, "normal writes produce no error reports")

-- Queue overflow is flushed as a batch. The per-file queue remains bounded.
local small = Logger.new({root=root,files={"bounded.log"},date=stamp,pending_limit_bytes=256})
for i=1,80 do check(small:append("bounded.log",string.rep("x",50) .. i), "overflow batches preserve accepted records") end
check(small:flush(), "last small-buffer batch flushes")
stats = small:snapshot()
check(stats.max_pending_bytes <= 256 and stats.lines == 80 and stats.dropped_lines == 0, "memory cap preserves all lines with healthy I/O")
check(stats.file_opens < 80, "even forced small batches use fewer opens than individual records")

local capped = Logger.new({root=root,files={"cap.log"},date=stamp,limit_bytes=512,pending_limit_bytes=256})
for i=1,50 do capped:append("cap.log",string.rep("z",40) .. i) end
check(capped:flush(), "capped log flush succeeds")
text = assert(read(root .. "/cap.log"))
check(#text <= 512, "file never exceeds configured size cap")
local _, markers = text:gsub("LOG SIZE LIMIT REACHED", "")
check(markers == 1 and capped:snapshot().suppressed_lines > 0, "cap has one visible marker and counted suppression")
local opens = capped:snapshot().file_opens
capped:append("cap.log","after cap"); capped:flush()
check(capped:snapshot().file_opens == opens, "capped logs do not reopen on every subsequent append")

local function fake_fs()
    local fs = {data={},fail_open=false,fail_write=false,fail_close=false,partial=false,opens=0,reports={}}
    local function open(path, mode)
        if mode == "rb" and fs.data[path] == nil then return nil,"missing" end
        if mode == "ab" then
            fs.opens=fs.opens+1
            if fs.fail_open then return nil,"simulated open failure" end
            fs.data[path] = fs.data[path] or ""
        end
        assert(mode == "rb" or mode == "ab", "logger uses binary mode for byte-accurate Windows file caps")
        local handle={}
        function handle:seek() return #fs.data[path] end
        function handle:write(batch)
            if fs.partial then fs.data[path]=fs.data[path] .. batch:sub(1,8); return nil,"partial write" end
            if fs.fail_write then return nil,"simulated write failure" end
            fs.data[path]=fs.data[path] .. batch; return self
        end
        function handle:close() if fs.fail_close then return nil,"simulated close failure" end; return true end
        return handle
    end
    local module=Logger.new({root="fake",files={"test.log"},open=open,date=stamp,
        pending_limit_bytes=256,limit_bytes=2048,remove=function(path) fs.data[path]=nil; return true end,
        rename=function(a,b) fs.data[b],fs.data[a]=fs.data[a],nil; return true end,
        report=function(s) fs.reports[#fs.reports+1]=s end})
    return fs,module
end

local fs, failed = fake_fs()
fs.fail_open=true
failed:append("test.log",string.rep("a",70)); failed:append("test.log",string.rep("b",70))
check(not failed:flush() and failed:snapshot().pending_bytes > 0, "open failure retains the original batch")
local attempts=fs.opens
for i=1,100 do failed:append("test.log",string.rep("c",70)) end
stats=failed:snapshot()
check(fs.opens==attempts, "full queue does not create per-line I/O retry storm")
check(stats.pending_bytes<=256 and stats.dropped_lines>0, "persistent failure keeps memory bounded and counts rejected lines")
check(#fs.reports==2, "I/O failure and overflow each report once")
fs.fail_open=false
check(failed:flush(), "scheduled flush retries and recovers")
check(fs.data["fake/test.log"]:find("LOGGER DROPPED",1,true), "recovery file explicitly identifies dropped records")
check(fs.data["fake/test.log"]:find(string.rep("a",70),1,true)
    and fs.data["fake/test.log"]:find(string.rep("b",70),1,true), "earliest retained records survive failure")
check(failed:snapshot().pending_bytes==0 and not failed:snapshot().files["test.log"].blocked, "recovery clears queue and retry block")
check(failed:append("test.log","after recovery") and failed:flush(), "logging resumes normally after recovery")

fs,failed=fake_fs()
failed:append("test.log","write failure record"); fs.fail_write=true
check(not failed:flush() and failed:snapshot().pending_bytes>0, "write failure retains pending data")
fs.fail_write=false
check(failed:flush() and fs.data["fake/test.log"]==stamp() .. "write failure record\n", "failed write retries complete original batch")

fs,failed=fake_fs()
failed:append("test.log","close failure record"); fs.fail_close=true
check(not failed:flush() and failed:snapshot().pending_bytes>0, "uncertain close retains data instead of claiming success")
check(fs.reports[1]:find("partial write may repeat",1,true), "uncertain partial outcome explicitly warns of possible repetition")
fs.fail_close=false
check(failed:flush(), "close failure is retryable")

fs,failed=fake_fs()
failed:append("test.log",string.rep("q",100)); fs.partial=true
for _=1,300 do failed:flush() end
check(#fs.data["fake/test.log"]<=2048, "partial retries cannot bypass on-disk cap")
fs.partial=false
check(failed:flush(), "partial-write failure recovers")

fs,failed=fake_fs()
check(not failed:append("test.log",string.rep("x",300)), "oversize single line is rejected before buffering")
check(failed:snapshot().pending_bytes==0 and failed:snapshot().dropped_lines==1, "oversize rejection is bounded and counted")
check(failed:flush() and fs.data["fake/test.log"]:find("LOGGER DROPPED 1",1,true), "oversize rejection has a visible recovery record")

print("LOGGER PASS: " .. count .. " assertions; batched I/O, bounded memory/file caps, rotation, retry and explicit loss reporting")
