-- Developer verification only: builds the portable core regression and a small
-- real C callback fixture. There is no game/UE4SS execution in these tests.
local tmp=assert(os.getenv("CCC_TEST_ROOT"),"CCC_TEST_ROOT is required")
local source=debug.getinfo(1,"S").source
assert(source:sub(1,1)=="@","test source must be a file")
local here=assert(source:sub(2):match("^(.*)[/\\][^/\\]+$"))
local function quote(s) return "'" .. s:gsub("'","'\\''") .. "'" end
local function command(s)
    local ok,kind,code=os.execute(s)
    assert(ok==true and code==0,s .. " failed: " .. tostring(kind) .. " " .. tostring(code))
end
local c=here .. "/test_guard_patch.c"
local exe=tmp .. "/test_guard_patch"
local library=tmp .. "/guard_count_fixture.so"
command("cc -std=c11 -Wall -Wextra -Werror " .. quote(c) .. " -o " .. quote(exe))
command(quote(exe))
command("cc -std=c11 -Wall -Wextra -Werror -shared -fPIC -DCCC_BUILD_LUA_FIXTURE " .. quote(c) .. " -o " .. quote(library))
local function call_native(f)
    return table.pack(f(false,false,false,false,false,false,false,false,
                        false,false,false,false,false,false,false,false))
end
for status=0,16 do
    local f,err=package.loadlib(library,"ccc_status_" .. status)
    assert(f,err)
    local results=call_native(f)
    assert(results.n==status,"actual Lua C result count mismatch for " .. status)
    for n=1,status do
        assert(results[n]==false,"native results must be the existing false sentinel arguments")
    end
end
print("PASS real Lua C bridge: status counts0..16 returned from existing sentinel arguments; no linked Lua C API")
