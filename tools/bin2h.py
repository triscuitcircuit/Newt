#!/usr/bin/env python3
import pathlib
import sys

src, dst, name = sys.argv[1], sys.argv[2], sys.argv[3]
data = pathlib.Path(src).read_bytes()
guard = "NEWT_GENERATED_" + name.upper() + "_H"
lines = [f"#ifndef {guard}", f"#define {guard}", f"static const unsigned char {name}[] = {{"]
for i in range(0, len(data), 16):
    lines.append("    " + ", ".join(f"0x{b:02x}" for b in data[i:i + 16]) + ",")
lines.append("};")
lines.append(f"static const unsigned int {name}_len = {len(data)};")
lines.append(f"#endif // {guard}")
pathlib.Path(dst).write_text("\n".join(lines) + "\n", encoding="utf-8")
