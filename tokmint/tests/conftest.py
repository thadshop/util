"""
Pytest fixtures. Patch secconfig so load_config runs under pytest tracing.
"""

import secconfig.loader as _sec_loader

# secconfig refuses load_config when sys.gettrace() is set (pytest); disable
# only for that guard, not the rest of loader behavior.
_sec_loader._check_no_debug = lambda: None  # noqa: SLF001
