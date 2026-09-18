import os
import asyncio
import logging
import ssl
from aiohttp import web
from metrics import record_trigger, record_webhook_request
from update import UpdateManager

CONFIG_PATH = os.environ.get("NOPS_CONFIG_PATH")
LOG_FILE = os.environ.get("NOPS_LOG_PATH", "/home/nops/log/main.log")

os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(name)s] [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("nops-webhook")

updater = UpdateManager(CONFIG_PATH)

def webhook_config():
    return updater.config.get("webhook", {})

def watched_branch():
    return webhook_config().get("branch", "main")

def push_event(payload):
    return (
        payload.get("object_kind") in (None, "push")
        and payload.get("event_type") in (None, "push")
        and "after" in payload
        and "ref" in payload
    )

def merge_request_event(payload):
    return payload.get("object_kind") == "merge_request" or payload.get("event_type") == "merge_request"

def push_should_trigger(payload):
    config = webhook_config()
    if not config.get("trigger_on_push", True):
        return False, "push events disabled", None

    expected_ref = f"refs/heads/{watched_branch()}"
    if payload.get("ref") != expected_ref:
        return False, f"push ref {payload.get('ref')} does not match {expected_ref}", None

    if payload.get("commits"):
        commit_msg = payload["commits"][0].get("message", "")
        if "[skip nops]" in commit_msg:
            return False, "skip flag in commit", None

    return True, "push accepted", payload.get("after", "webhook-push")

def merge_request_should_trigger(payload):
    config = webhook_config()
    attrs = payload.get("object_attributes") or {}
    action = attrs.get("action")

    if action != "merge":
        return False, f"merge request action {action} ignored", None
    if not config.get("trigger_on_merge_request_merge", False):
        return False, "merge request merge events disabled", None
    if attrs.get("target_branch") != watched_branch():
        return False, f"merge request target {attrs.get('target_branch')} does not match {watched_branch()}", None

    trigger_id = attrs.get("merge_commit_sha") or (attrs.get("last_commit") or {}).get("id") or "webhook-merge-request"
    return True, "merge request merge accepted", trigger_id

def classify_webhook(payload):
    if merge_request_event(payload):
        return merge_request_should_trigger(payload)
    if push_event(payload):
        return push_should_trigger(payload)
    return False, "unsupported webhook event ignored", None

# Accepts POST from Forgejo/GitLab/GitHub and triggers updates for configured push or GitLab merge request events.
async def handle_webhook(request):
    logger.info("WEBHOOK EVENT DETECTED")
    record_trigger("webhook")

    try:
        payload = await request.json()
        should_trigger, reason, trigger_id = classify_webhook(payload)
        if not should_trigger:
            logger.info(f"IGNORING WEBHOOK: {reason}")
            record_webhook_request("skipped")
            return web.Response(text=f"Ignored: {reason}.\n", status=200)
    except Exception as e:
        logger.warning(f"INVALID WEBHOOK PAYLOAD: {e}")
        record_webhook_request("invalid")
        return web.Response(text="Invalid webhook payload.\n", status=400)
        
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, updater.perform_update, trigger_id, "webhook")
    record_webhook_request("accepted")
    
    return web.Response(text="Nops Update Triggered successfully.\n")

# Runs the boot sync and registers POST handlers at / and /webhook.
async def init_app():
    logger.info("INITIALIZING NOPS-WEBHOOK...")
    try:
        updater.run_boot_sequence()
    except Exception as e:
        logger.error(f"STARTUP SYNC FAILED: {e}")

    app = web.Application()
    app.router.add_post('/webhook', handle_webhook)
    app.router.add_post('/', handle_webhook)
    return app

if __name__ == '__main__':
    port = int(os.environ.get("WEBHOOK_PORT", "8080"))
    cert_file = os.environ.get("WEBHOOK_SSL_CERT", "")
    key_file = os.environ.get("WEBHOOK_SSL_KEY", "")

    ssl_context = None
    if cert_file and key_file:
        logger.info(f"CONFIGURING SSL WITH CERT: {cert_file}")
        ssl_context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_context.load_cert_chain(certfile=cert_file, keyfile=key_file)
        logger.info(f"STARTING NOPS-WEBHOOK ON PORT {port} WITH SSL")
    else:
        logger.info(f"STARTING NOPS-WEBHOOK ON PORT {port} (HTTP ONLY)")

    web.run_app(init_app(), host='0.0.0.0', port=port, ssl_context=ssl_context)
