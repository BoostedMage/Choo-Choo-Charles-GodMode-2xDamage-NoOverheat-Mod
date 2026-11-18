"""Optional developer build. The ready-to-use Windows DLL is already packaged."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import tempfile

here = Path(__file__).resolve().parent
compiler = os.environ.get("CCC_ZIG") or shutil.which("zig")
if not compiler:
    raise SystemExit("Set CCC_ZIG to a Zig 0.13.0 compiler executable. Players do not need this tool.")
destination = here.parent / "Mod/ChooChooCharles_GodMode/Scripts/native/ccc_guard.dll"
with tempfile.TemporaryDirectory(prefix="ccc_native_build_") as temporary:
    output = Path(temporary) / "ccc_guard.dll"
    command = [compiler, "cc", "-target", "x86_64-windows-gnu", "-shared", "-O2", "-s",
               "-fms-extensions", "-fno-ident", "-Werror", "-Wall", "-Wextra",
               "-o", str(output), str(here / "ccc_guard_win.c"), "-lkernel32"]
    subprocess.run(command, check=True)
    data = output.read_bytes()
    if data[:2] != b"MZ":
        raise RuntimeError("Compiler did not produce a PE DLL")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
print("Built Windows x64 companion:", destination)
print("SHA256:", hashlib.sha256(data).hexdigest())
