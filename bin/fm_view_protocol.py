"""Read-only view protocol constants shared by native readers and preflight.

This is not monitoring, installation, lifecycle or transaction capability.
Changing an admitted verb or bound requires updating its owning behavior tests.
"""
PROTOCOL = "fm-supervision-views.v1"
VERBS = ("status-fold", "crew-state", "status-presentation", "drain-presentation",
         "status-backstop", "snapshot-tasks")
MIN_PYTHON = (3, 9)
MAX_MESSAGE = 1024 * 1024
MAX_FILE = 4 * 1024 * 1024
MAX_CLIENTS = 64
MAX_TIMEOUT = 30.0
MAX_WORKERS = 16
MAX_CRITICAL_WORKERS = 4
