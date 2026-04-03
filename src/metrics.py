import os
import time

from prometheus_client import Counter, Gauge, Histogram


NOPS_INFO = Gauge(
    "nops_build_info",
    "Static information about the running nops build.",
    ["version"],
)
NOPS_INFO.labels(version=os.environ.get("NOPS_VERSION", "dev")).set(1)

UPDATE_TRIGGERS = Counter(
    "nops_update_triggers_total",
    "Number of update triggers received by nops.",
    ["source"],
)
UPDATE_RUNS = Counter(
    "nops_update_runs_total",
    "Number of completed nops update runs.",
    ["source", "result"],
)
UPDATE_DURATION = Histogram(
    "nops_update_duration_seconds",
    "Duration of nops update runs in seconds.",
    ["source"],
)
LAST_UPDATE_UNIX = Gauge(
    "nops_last_update_timestamp_seconds",
    "Unix timestamp of the last completed nops update run.",
    ["source", "result"],
    multiprocess_mode="livemostrecent",
)
WEBHOOK_REQUESTS = Counter(
    "nops_webhook_requests_total",
    "Number of webhook requests handled by nops.",
    ["status"],
)
BOOT_RUNS = Counter(
    "nops_boot_sync_total",
    "Number of nops boot synchronization attempts.",
    ["result"],
)
LAST_BOOT_SYNC_UNIX = Gauge(
    "nops_last_boot_sync_timestamp_seconds",
    "Unix timestamp of the last successful nops boot synchronization.",
    multiprocess_mode="livemostrecent",
)


def _now() -> float:
    return time.time()


def record_trigger(source: str) -> None:
    UPDATE_TRIGGERS.labels(source=source).inc()


def record_webhook_request(status: str) -> None:
    WEBHOOK_REQUESTS.labels(status=status).inc()


def record_update_result(source: str, result: str, duration_seconds: float) -> None:
    UPDATE_RUNS.labels(source=source, result=result).inc()
    UPDATE_DURATION.labels(source=source).observe(duration_seconds)
    LAST_UPDATE_UNIX.labels(source=source, result=result).set(_now())


def record_boot_sync(result: str) -> None:
    BOOT_RUNS.labels(result=result).inc()
    if result == "success":
        LAST_BOOT_SYNC_UNIX.set(_now())