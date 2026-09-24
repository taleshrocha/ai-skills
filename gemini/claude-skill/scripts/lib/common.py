"""Shared helpers for the Gemini delegation runner."""

import re

_PATTERNS = [
    (r'(?i)(PRIVATE-TOKEN\s*[:=]\s*)[^\s,"\']+', r'\1[REDACTED]'),
    (r'(?i)(Authorization\s*:\s*Bearer\s+)[^\s,"\']+', r'\1[REDACTED]'),
    (r'(?i)\b(password|passwd|secret|token|api[_-]?key|secret[_-]?id|access[_-]?key)\b\s*([=:])\s*[^\s,"\']+',
     r'\1\2[REDACTED]'),
    (r'glpat-[A-Za-z0-9_-]{10,}', '[REDACTED_GITLAB_TOKEN]'),
    (r'gh[pousr]_[A-Za-z0-9]{20,}', '[REDACTED_GITHUB_TOKEN]'),
    (r'AKIA[0-9A-Z]{16}', '[REDACTED_AWS_KEY]'),
    (r'-----BEGIN [^-]+ PRIVATE KEY-----.*?-----END [^-]+ PRIVATE KEY-----', '[REDACTED_PRIVATE_KEY]'),
]


def redact(value):
    """Strip credential-shaped substrings from anything we are about to print."""
    if not isinstance(value, str):
        return value
    for pattern, replacement in _PATTERNS:
        value = re.sub(pattern, replacement, value, flags=re.DOTALL)
    return value


def clip(value, limit):
    value = "" if value is None else str(value)
    value = " ".join(value.split())
    return value if len(value) <= limit else value[: limit - 1] + "…"


def short_path(path, keep=3):
    """Shorten an absolute path to its last few segments so digests stay narrow."""
    if not isinstance(path, str) or "/" not in path:
        return path
    parts = [p for p in path.split("/") if p]
    if len(parts) <= keep:
        return "/".join(parts)
    return ".../" + "/".join(parts[-keep:])
