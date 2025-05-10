#!/usr/bin/env python3

import os
import subprocess
import logging
from datetime import datetime
import shutil

LOCAL_REPOS_BASE_DIR = "/var/git" # personal gitea directory, yours may differ

GITHUB_USER_OR_ORG = "fddldev" # my github account name, obviously change this to yours

MIRROR_WORK_DIR = "/home/tristan/github_mirror"

USE_GH_FOR_REPO_CREATION = True
GH_REPO_VISIBILITY = "--public"

LOG_FILE = os.path.join(MIRROR_WORK_DIR, "mirror_sync_python.log")

def setup_logging():
    """Sets up logging to file and console."""
    os.makedirs(MIRROR_WORK_DIR, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
        handlers=[
            logging.FileHandler(LOG_FILE),
            logging.StreamHandler()
        ]
    )

def run_command(command, cwd=None, check=True, suppress_output=False):
    """
    Runs a shell command and logs its execution.
    Returns the subprocess.CompletedProcess object.
    Raises subprocess.CalledProcessError if 'check' is True and command fails.
    """
    cmd_str = ' '.join(command)
    logging.info(f"Running command: {cmd_str} in {cwd or os.getcwd()}")
    try:
        process = subprocess.run(
            command,
            cwd=cwd,
            check=check,
            text=True,
            capture_output=True
        )
        if not suppress_output:
            if process.stdout:
                logging.info(f"STDOUT:\n{process.stdout.strip()}")
            
            if process.stderr:
                logging.info(f"STDERR:\n{process.stderr.strip()}")
        return process
    except subprocess.CalledProcessError as e:
        logging.error(f"Error running command: {' '.join(e.cmd)}")
        if e.stdout:
            logging.error(f"STDOUT:\n{e.stdout.strip()}")
        if e.stderr:
            logging.error(f"STDERR:\n{e.stderr.strip()}")
        raise
    except FileNotFoundError:
        logging.error(f"Error: The command '{command[0]}' was not found. Is it installed and in PATH?")
        raise


def main():
    setup_logging()
    logging.info(f"--- Starting GitHub Mirror Sync (Python): {datetime.now()} ---")

    if GITHUB_USER_OR_ORG == "your-github-username-or-org":
        logging.error("CRITICAL: Please update GITHUB_USER_OR_ORG in the script.")
        print("ERROR: Please update GITHUB_USER_OR_ORG in the script before running.")
        return

    if not shutil.which("git"):
        logging.error("CRITICAL: 'git' command not found. Please install Git and ensure it's in your PATH.")
        return

    if USE_GH_FOR_REPO_CREATION and not shutil.which("gh"):
        logging.error("CRITICAL: 'gh' command not found, but USE_GH_FOR_REPO_CREATION is True. "
                      "Please install GitHub CLI or set USE_GH_FOR_REPO_CREATION to False.")
        return


    if not os.path.isdir(LOCAL_REPOS_BASE_DIR):
        logging.error(f"Local repositories base directory '{LOCAL_REPOS_BASE_DIR}' does not exist.")
        return

    try:
        os.makedirs(MIRROR_WORK_DIR, exist_ok=True)
        if not os.access(MIRROR_WORK_DIR, os.W_OK):
            raise OSError(f"Directory {MIRROR_WORK_DIR} is not writable.")
    except OSError as e:
        logging.error(f"Mirror working directory error: {e}")
        return

    for item in os.listdir(LOCAL_REPOS_BASE_DIR):
        local_repo_path_on_server = os.path.join(LOCAL_REPOS_BASE_DIR, item)

        if os.path.isdir(local_repo_path_on_server) and item.endswith(".git"):
            repo_name_with_git = item
            repo_name = item[:-4] 

            logging.info(f"\nProcessing repository: {repo_name}")

            local_mirror_clone_path = os.path.join(MIRROR_WORK_DIR, repo_name_with_git)
            github_repo_url = f"git@github.com:{GITHUB_USER_OR_ORG}/{repo_name}.git"
            local_server_source_url = f"file://{os.path.abspath(local_repo_path_on_server)}"

            try:
                if not os.path.isdir(local_mirror_clone_path):
                    logging.info(f"Action: New repository or first-time sync for '{repo_name}'.")

                    if USE_GH_FOR_REPO_CREATION:
                        logging.info(f"Checking if repository '{GITHUB_USER_OR_ORG}/{repo_name}' exists on GitHub...")
                        try:
                            gh_view_cmd = ["gh", "repo", "view", f"{GITHUB_USER_OR_ORG}/{repo_name}"]
                            process_gh_view = run_command(gh_view_cmd, check=False, suppress_output=True)

                            if process_gh_view.returncode != 0: 
                                logging.info(f"Repository does not appear to exist on GitHub (gh repo view failed). Attempting to create it...")
                                gh_create_cmd = [
                                    "gh", "repo", "create", f"{GITHUB_USER_OR_ORG}/{repo_name}",
                                    GH_REPO_VISIBILITY,
                                    "--description", f"Mirror of git.fddl.dev repo {repo_name}"
                                ]
                                run_command(gh_create_cmd)
                                logging.info(f"Successfully created '{GITHUB_USER_OR_ORG}/{repo_name}' on GitHub via gh CLI.")
                            else:
                                logging.info(f"Repository '{GITHUB_USER_OR_ORG}/{repo_name}' already exists on GitHub.")
                        except FileNotFoundError:
                            logging.error("GitHub CLI 'gh' not found. Cannot auto-create repositories. Please install it or set USE_GH_FOR_REPO_CREATION to False.")
                            logging.info("You'll need to ensure the repository exists on GitHub manually for the push to succeed.")
                        except subprocess.CalledProcessError as e_gh:
                            logging.error(f"Error during GitHub repo check/create for {repo_name}: {e_gh}")
                            logging.info("Please ensure the repository exists on GitHub manually for the push to succeed.")

                    logging.info(f"Cloning from local server: '{local_server_source_url}' to '{local_mirror_clone_path}'")
                    run_command(["git", "clone", "--mirror", local_server_source_url, local_mirror_clone_path])

                    logging.info(f"Adding GitHub remote 'github' with URL '{github_repo_url}'")
                    try:
                        run_command(["git", "remote", "add", "github", github_repo_url], cwd=local_mirror_clone_path)
                    except subprocess.CalledProcessError:
                        logging.warning("Failed to add GitHub remote (it might already exist). Attempting to set URL.")
                        run_command(["git", "remote", "set-url", "github", github_repo_url], cwd=local_mirror_clone_path)
                    logging.info("GitHub remote 'github' configured.")

                else: 
                    logging.info(f"Action: Existing repository '{repo_name}' in work area. Fetching updates from local server.")
                    logging.info(f"Ensuring 'origin' remote in '{local_mirror_clone_path}' points to '{local_server_source_url}'")
                    run_command(["git", "remote", "set-url", "origin", local_server_source_url], cwd=local_mirror_clone_path)

                    logging.info("Fetching from 'origin' (local server)...")
                    run_command(["git", "fetch", "--prune", "origin"], cwd=local_mirror_clone_path)
                    logging.info("Successfully fetched updates from local server.")

                logging.info(f"Pushing mirror of '{repo_name}' to GitHub remote: '{github_repo_url}'")
                run_command(["git", "config", "--global", "--add", "safe.directory", local_mirror_clone_path], cwd=local_mirror_clone_path)
                run_command(["git", "push", "--mirror", "github"], cwd=local_mirror_clone_path)
                logging.info(f"Successfully mirrored '{repo_name}' to GitHub.")

            except subprocess.CalledProcessError:
                logging.error(f"A Git command failed for repository '{repo_name}'. Details logged above. Skipping further actions for this repo.")
            except FileNotFoundError: 
                logging.error(f"A required command (like git) was not found while processing '{repo_name}'.")
                return 
            except Exception as e:
                logging.error(f"An unexpected error occurred while processing repository '{repo_name}': {str(e)}")

    logging.info(f"--- GitHub Mirror Sync (Python) Finished: {datetime.now()} ---")
    logging.info("")


if __name__ == "__main__":
    main()