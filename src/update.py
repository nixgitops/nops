import os
import subprocess
import logging
import json
import time
from typing import List, Dict, Any

from metrics import record_boot_sync, record_update_result

logger = logging.getLogger("nops-update")

# Executes git fetch/reset and nixos-rebuild commands derived from the JSON config produced by the nops NixOS module.
class UpdateManager:
    __slots__ = ('config_path', 'config', 'hostname')

    # Loads config from the Nix-generated JSON file at config_path.
    def __init__(self, config_path: str):
        self.config_path = config_path
        self.config = self._load_config()
        self.hostname = subprocess.getoutput("hostname")

    # Reads and parses the Nix-generated JSON config file; raises on failure.
    def _load_config(self) -> Dict[str, Any]:
        try:
            with open(self.config_path, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"FAILED TO LOAD NOPS CONFIG: {e}")
            raise

    # Runs a subprocess, streams stdout/stderr to the logger under the given stage label, and raises CalledProcessError on non-zero exit.
    def _run_command(self, cmd: List[str], cwd: str, stage: str) -> str:
        command_str = " ".join(cmd)
        logger.info(f"{stage} START: {command_str}")

        result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)

        if result.stdout:
            for line in result.stdout.splitlines():
                logger.info(f"{stage} OUTPUT: {line}")

        if result.stderr:
            log_func = logger.error if result.returncode != 0 else logger.info
            for line in result.stderr.splitlines():
                log_func(f"{stage} MESSAGE: {line}")

        if result.returncode != 0:
            logger.error(f"{stage} FAILED WITH CODE {result.returncode}")
            raise subprocess.CalledProcessError(result.returncode, cmd, output=result.stdout, stderr=result.stderr)

        logger.info(f"{stage} SUCCESS: {command_str}")
        return result.stdout.strip()

    # Returns files differing between local HEAD and origin/main; returns an empty list on error.
    def _get_changed_files(self, repo_dir: str) -> List[str]:
        try:
            output = self._run_command(["git", "diff", "--name-only", "HEAD", "origin/main"], cwd=repo_dir, stage="GIT-DIFF")
            return output.splitlines()
        except Exception:
            return []

    # Returns True if any changed path falls under this node's directory, shared groups/, modules/, secrets/, or flake files.
    def _should_rebuild(self, changed_files: List[str]) -> bool:
        if not changed_files:
            return False

        relevant_paths = [
            f"nodes/{self.hostname}/",
            "groups/",    
            "modules/",   
            "secrets/",
            "scripts/",
            "flake.nix",
            "flake.lock"
        ]
        
        for f in changed_files:
            if any(f.startswith(path) for path in relevant_paths):
                logger.info(f"RELEVANT CHANGE DETECTED: {f}")
                return True
        
        return False

    # Executes the update pipeline.
    # Fetches the remote repository to evaluate changes before running controller logic to avoid masking triggering commits.
    # Forces a rebuild if the node acts as a controller, otherwise evaluates changes for follower nodes.
    def perform_update(self, trigger_id: str, source: str = "unknown") -> str:
        logger.info(f"NOPS UPDATE SEQUENCE INITIATED: {trigger_id}")
        repo_dir = self.config['directories']['repo']
        is_controller = self.config.get('is_controller', False)
        controller_script = self.config.get('controller_script', "")
        started_at = time.monotonic()

        try:
            self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="GIT-FETCH")
            changed_files = self._get_changed_files(repo_dir)
            needs_rebuild = self._should_rebuild(changed_files)

            if is_controller and controller_script:
                logger.info("NODE IS CONTROLLER. SYNCING REPO BEFORE CONTROLLER SCRIPT...")
                # Reset to latest commit BEFORE running controller so it has access to new files (e.g. terraform configs, updated secrets)
                self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="GIT-RESET-PRE")

                logger.info("EXECUTING CONTROLLER SCRIPT...")
                import os
                script_path = "/tmp/nops_controller.sh"
                with open(script_path, "w") as f:
                    f.write(controller_script)
                os.chmod(script_path, 0o755)
                try:
                    self._run_command(["bash", "-c", script_path], cwd=repo_dir, stage="CONTROLLER-HOOK")
                except subprocess.CalledProcessError as e:
                    logger.warning(f"CONTROLLER-HOOK FAILED (non-fatal, continuing with rebuild): {e}")

                # Re-fetch in case controller script pushed new commits (e.g. re-keyed secrets)
                self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="GIT-FETCH-POST")
                needs_rebuild = True

            elif not is_controller:
                logger.info("NODE IS FOLLOWER. PAUSING 30s FOR CONTROLLER TO PROVISION SECRETS...")
                import time
                time.sleep(30)
                
                self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="GIT-FETCH-POST")
                changed_files = self._get_changed_files(repo_dir)
                needs_rebuild = self._should_rebuild(changed_files)

            if not needs_rebuild:
                self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="GIT-RESET")
                logger.info("NO RELEVANT CHANGES FOUND. RESETTING REPO.")
                record_update_result(source, "skipped", time.monotonic() - started_at)
                return "SKIPPED"

            self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="GIT-RESET")
            
            rebuild_cmds = self.config['commands']['update']
            output_log = ""
            if isinstance(rebuild_cmds, list):
                for cmd in rebuild_cmds:
                    output_log += self._run_command(["bash", "-c", cmd], cwd=repo_dir, stage="REBUILD") + "\n"
            else:
                output_log = self._run_command(["bash", "-c", rebuild_cmds], cwd=repo_dir, stage="REBUILD")
            
            logger.info(f"NOPS REBUILD TASK COMPLETED: {trigger_id}")
            record_update_result(source, "success", time.monotonic() - started_at)
            return output_log.strip()

        except Exception as e:
            logger.error(f"NOPS UPDATE PIPELINE FAILED: {str(e)}")
            record_update_result(source, "failure", time.monotonic() - started_at)
            return f"FAILURE: {str(e)}"

    # Fetches origin and hard-resets to origin/main so the daemon starts with current fleet state.
    def run_boot_sequence(self):
        repo_dir = self.config['directories']['repo']
        logger.info("INITIALIZING BOOT SYNCHRONIZATION...")
        try:
            self._run_command(["git", "fetch", "origin"], cwd=repo_dir, stage="BOOT")
            self._run_command(["git", "reset", "--hard", "origin/main"], cwd=repo_dir, stage="BOOT")
            record_boot_sync("success")
        except Exception as e:
            logger.error(f"BOOT SYNC FAILED: {e}")
            record_boot_sync("failure")