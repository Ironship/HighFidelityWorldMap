"""Lua literal formatting for generated tables."""

from __future__ import annotations


def lua_string(value: str) -> str:
    """Quote *value* as a Lua string literal."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def lua_int_array(values: list[int]) -> str:
    return "{ " + ", ".join(str(v) for v in values) + " }"


def lua_num(value: float) -> str:
    """Format a number without a trailing ``.0``, which Lua does not need."""
    if value == int(value):
        return str(int(value))
    return repr(round(value, 2))


def lua_bounds(bounds: list[float] | None) -> str:
    if not bounds:
        return "nil"
    return "{ " + ", ".join(lua_num(v) for v in bounds) + " }"
