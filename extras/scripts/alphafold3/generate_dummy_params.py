
# original version of this code at
# https://github.com/google-deepmind/alphafold3/blob/main/docs/model_parameters.md
# created by Augustin Žídek at Google DeepMind

from alphafold3.model import params
import numpy as np
import zstandard
import ast
import re

DTYPE_MAP = {
    "float32": np.float32,
    "uint8": np.uint8,
    "bfloat16": np.float32,
}

NAME_RE = re.compile(r"name=([^\s]+)")
DTYPE_RE = re.compile(r"dtype=([^\s]+)")
SHAPE_RE = re.compile(r"shape=\(")

parameters = []

with open("schema.txt", "r", encoding="utf-8", errors="ignore") as f:
    pending_shape = None
    pending_name = None
    pending_dtype = None
    paren_depth = 0
    shape_buf = ""

    for line in f:
        if pending_name is None:
            name_match = NAME_RE.search(line)
            dtype_match = DTYPE_RE.search(line)

            if not name_match or not dtype_match:
                continue

            pending_name = name_match.group(1)
            pending_dtype = dtype_match.group(1)

            if "shape=" not in line:
                continue

            shape_start = line.split("shape=", 1)[1]
            shape_buf = shape_start
            paren_depth = shape_start.count("(") - shape_start.count(")")

        else:
            shape_buf += line
            paren_depth += line.count("(") - line.count(")")

        if pending_name is not None and paren_depth == 0 and shape_buf:
            shape_str = shape_buf.strip()
            if not shape_str.startswith("("):
                shape_str = shape_str[shape_str.find("("):]

            shape = ast.literal_eval(shape_str)
            dtype = DTYPE_MAP[pending_dtype]

            parameters.append((pending_name, shape, dtype))

            pending_name = None
            pending_dtype = None
            shape_buf = ""
            paren_depth = 0

print(f"Parsed {len(parameters)} parameters")

with zstandard.open("random_weights.bin.zst", "wb") as compressed:
    for scope_name, shape, dtype in parameters:

        if scope_name == "__meta__:__identifier__":
            arr = np.zeros(shape=shape, dtype=dtype)
        else:
            arr = np.random.uniform(-1, 1, size=shape).astype(dtype)

        compressed.write(
            params.encode_record(*scope_name.split(":"), arr)
        )
