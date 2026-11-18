"""Execute Lua sources with the installed Lua 5.4 shared library, no UE4SS claim."""
from pathlib import Path
import ctypes
import ctypes.util
import os
import sys
import tempfile

library = ctypes.util.find_library("lua5.4")
if not library:
    raise SystemExit("Developer verification requires a Lua 5.4 shared library; the game installer does not require it.")
lua = ctypes.CDLL(library)
lua.luaL_newstate.restype = ctypes.c_void_p
lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
lua.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lua.luaL_loadfilex.restype = ctypes.c_int
lua.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_void_p]
lua.lua_pcallk.restype = ctypes.c_int
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
lua.lua_tolstring.restype = ctypes.c_char_p
lua.lua_close.argtypes = [ctypes.c_void_p]

syntax_only = "--syntax" in sys.argv
verification_dir = Path(__file__).resolve().parent
scripts_dir = (verification_dir.parent / "Mod/ChooChooCharles_GodMode/Scripts"
               if verification_dir.name == "Verification" else verification_dir)
os.environ["CCC_MOD_SCRIPTS"] = str(scripts_dir)
temporary = tempfile.TemporaryDirectory(prefix="CCC_Lua_Test_")
os.environ["CCC_TEST_ROOT"] = temporary.name
Path(temporary.name, "Scripts").mkdir()
files = [Path(p) for p in sys.argv[1:] if p != "--syntax"]
if not files:
    files = sorted(verification_dir.glob("test_*.lua"))
for path in files:
    state = lua.luaL_newstate()
    try:
        lua.luaL_openlibs(state)
        status = lua.luaL_loadfilex(state, str(path).encode(), None)
        if status == 0 and not syntax_only:
            status = lua.lua_pcallk(state, 0, 0, 0, 0, None)
        if status:
            message = lua.lua_tolstring(state, -1, None)
            raise RuntimeError(f"{path}: {message.decode() if message else 'Lua error'}")
        if syntax_only:
            print(f"SYNTAX PASS {path}")
    finally:
        lua.lua_close(state)
temporary.cleanup()
