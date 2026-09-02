#!/usr/bin/env bash
#
# Install the shared Claude Code permission rules into ~/.claude/settings.json.
#
# WHY THIS EXISTS
#
# The rules live in this repo at .claude/settings.json, which Claude Code reads
# only for sessions whose project IS this repo. Two situations that file cannot
# cover:
#
#   1. Other repositories. A project-scoped file says nothing about the repo you
#      open next, so every Railway call and every `pytest` prompts again there.
#
#   2. Cloud session containers. Claude Code on the web builds a fresh container
#      per environment and ~/.claude/ starts empty, so a file copied by hand on
#      a laptop is simply absent. (This is the same reason .claude/skills/ and
#      .claude/settings.json are committed rather than left ignored.)
#
# Run this from the environment setup script (claude.ai -> environment settings)
# and every cloud session in that environment starts with the rules already on
# disk, for every repository it opens.
#
# ORDERING MATTERS, AND IS THE WHOLE POINT
#
# Claude Code resolves permissions ONCE, when a session starts. An environment
# setup script runs when the CONTAINER is built -- before any session -- so the
# file is in place in time.
#
# Do NOT wire this as a SessionStart hook instead. That fires as part of session
# startup, i.e. at or after the moment permissions are read, so the rules would
# take effect from the *next* session in that container rather than the one the
# user is looking at. A guard that silently applies one session late is worse
# than no guard, because it tests as working.
#
# SAFETY
#
#   - Idempotent. Safe to run on every container build.
#   - Never clobbers an existing ~/.claude/settings.json: it MERGES the allow
#     and ask arrays and leaves every other key alone.
#   - Validates the result and fails loudly. A malformed settings.json silently
#     disables every rule in it, so "wrote a broken file" must never be quiet.
#
set -euo pipefail

TARGET="${HOME}/.claude/settings.json"
TMP="$(mktemp)"
trap 'rm -f "$TMP" "$TMP.merged"' EXIT

cat > "$TMP" <<'CLAUDE_SETTINGS_EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "mcp__Railway__add_custom_domain",
      "mcp__Railway__check_endpoint",
      "mcp__Railway__create_domain",
      "mcp__Railway__create_environment",
      "mcp__Railway__create_project",
      "mcp__Railway__create_schedule",
      "mcp__Railway__create_service",
      "mcp__Railway__create_volume",
      "mcp__Railway__create_volume_backup",
      "mcp__Railway__db_query",
      "mcp__Railway__deploy_and_verify",
      "mcp__Railway__deploy_template",
      "mcp__Railway__find_template",
      "mcp__Railway__get_audit_log",
      "mcp__Railway__get_connector_info",
      "mcp__Railway__get_deploy_logs",
      "mcp__Railway__get_http_logs",
      "mcp__Railway__get_http_metrics",
      "mcp__Railway__get_metrics",
      "mcp__Railway__get_project_overview",
      "mcp__Railway__get_safety_policy",
      "mcp__Railway__get_service_info",
      "mcp__Railway__get_usage",
      "mcp__Railway__get_variables",
      "mcp__Railway__git_clone",
      "mcp__Railway__git_commit_push",
      "mcp__Railway__git_status",
      "mcp__Railway__job_logs",
      "mcp__Railway__job_status",
      "mcp__Railway__list_databases",
      "mcp__Railway__list_deployments",
      "mcp__Railway__list_domains",
      "mcp__Railway__list_environments",
      "mcp__Railway__list_files",
      "mcp__Railway__list_jobs",
      "mcp__Railway__list_projects",
      "mcp__Railway__list_schedules",
      "mcp__Railway__list_services",
      "mcp__Railway__list_volume_backups",
      "mcp__Railway__list_volumes",
      "mcp__Railway__railway_cli",
      "mcp__Railway__railway_ssh",
      "mcp__Railway__read_file",
      "mcp__Railway__redeploy_service",
      "mcp__Railway__restart_deployment",
      "mcp__Railway__rollback_deployment",
      "mcp__Railway__run_command",
      "mcp__Railway__run_schedule_now",
      "mcp__Railway__set_variables",
      "mcp__Railway__setup_ssh_key",
      "mcp__Railway__ssh_key_status",
      "mcp__Railway__start_job",
      "mcp__Railway__stop_deployment",
      "mcp__Railway__stop_job",
      "mcp__Railway__update_service_config",
      "mcp__Railway__wait_for_deployment",
      "mcp__Railway__wait_for_job",
      "mcp__Railway__whoami",
      "mcp__Railway__write_file",
      "Read",
      "Glob",
      "Grep",
      "Bash(railway *)",
      "Bash(railway:*)",
      "Bash(git status *)",
      "Bash(git status:*)",
      "Bash(git diff *)",
      "Bash(git diff:*)",
      "Bash(git log *)",
      "Bash(git log:*)",
      "Bash(git show *)",
      "Bash(git show:*)",
      "Bash(git branch *)",
      "Bash(git branch:*)",
      "Bash(git remote *)",
      "Bash(git remote:*)",
      "Bash(git fetch *)",
      "Bash(git fetch:*)",
      "Bash(git rev-parse *)",
      "Bash(git rev-parse:*)",
      "Bash(git check-ignore *)",
      "Bash(git check-ignore:*)",
      "Bash(git add *)",
      "Bash(git add:*)",
      "Bash(git commit *)",
      "Bash(git commit:*)",
      "Bash(npm run *)",
      "Bash(npm run:*)",
      "Bash(npm test *)",
      "Bash(npm test:*)",
      "Bash(npm ci *)",
      "Bash(npm ci:*)",
      "Bash(npm install *)",
      "Bash(npm install:*)",
      "Bash(npx tsc *)",
      "Bash(npx tsc:*)",
      "Bash(pytest *)",
      "Bash(pytest:*)",
      "Bash(python -m pytest *)",
      "Bash(python -m pytest:*)",
      "Bash(ruff *)",
      "Bash(ruff:*)",
      "Bash(alembic heads *)",
      "Bash(alembic heads:*)",
      "Bash(alembic current *)",
      "Bash(alembic current:*)",
      "Bash(alembic history *)",
      "Bash(alembic history:*)",
      "Bash(ls *)",
      "Bash(ls:*)",
      "Bash(cat *)",
      "Bash(cat:*)",
      "Bash(head *)",
      "Bash(head:*)",
      "Bash(tail *)",
      "Bash(tail:*)",
      "Bash(wc *)",
      "Bash(wc:*)",
      "Bash(find *)",
      "Bash(find:*)",
      "Bash(grep *)",
      "Bash(grep:*)",
      "Bash(rg *)",
      "Bash(rg:*)",
      "Bash(jq *)",
      "Bash(jq:*)",
      "Bash(echo *)",
      "Bash(echo:*)",
      "Bash(pwd *)",
      "Bash(pwd:*)",
      "Bash(which *)",
      "Bash(which:*)",
      "Bash(file *)",
      "Bash(file:*)",
      "Bash(stat *)",
      "Bash(stat:*)",
      "Bash(diff *)",
      "Bash(diff:*)",
      "Bash(sort *)",
      "Bash(sort:*)",
      "Bash(uniq *)",
      "Bash(uniq:*)",
      "Bash(git push *)",
      "Bash(git push:*)"
    ],
    "ask": [
      "mcp__Railway__delete_domain",
      "mcp__Railway__delete_environment",
      "mcp__Railway__delete_path",
      "mcp__Railway__delete_schedule",
      "mcp__Railway__delete_service",
      "mcp__Railway__delete_variable",
      "mcp__Railway__delete_volume",
      "mcp__Railway__restore_volume_backup",
      "Bash(git push --force *)",
      "Bash(git push --force:*)",
      "Bash(git push -f *)",
      "Bash(git push -f:*)",
      "Bash(git push origin --force *)",
      "Bash(git push origin --force:*)"
    ]
  }
}
CLAUDE_SETTINGS_EOF

have() { command -v "$1" >/dev/null 2>&1; }

if have jq; then
  VALIDATE='jq -e . >/dev/null'
elif have python3; then
  VALIDATE='python3 -c "import json,sys; json.load(sys.stdin)"'
else
  echo "setup-claude-permissions: neither jq nor python3 available; cannot validate JSON." >&2
  echo "  Refusing to write ${TARGET} unverified." >&2
  exit 1
fi

# Drift check: if this script is run from inside the repo that owns the rules,
# say so when the embedded snapshot and the committed file have diverged. One
# of the two was edited and the other forgotten; silence here is how the global
# file quietly falls a release behind the project one.
# Compare only the permissions block: a repo's settings.json legitimately
# carries other keys (hooks, theme), and a whole-file diff would warn on every
# run in those repos. A warning that always fires is one nobody reads.
REPO_SETTINGS="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/.claude/settings.json"
if [ -f "$REPO_SETTINGS" ] && have jq \
   && ! diff -q <(jq -S '.permissions' "$REPO_SETTINGS" 2>/dev/null) \
                <(jq -S '.permissions' "$TMP") >/dev/null 2>&1; then
  echo "setup-claude-permissions: NOTE - embedded rules differ from ${REPO_SETTINGS}." >&2
  echo "  Regenerate this script from that file so the two do not drift." >&2
fi

mkdir -p "${HOME}/.claude"

if [ ! -f "$TARGET" ]; then
  eval "$VALIDATE" < "$TMP"
  cp "$TMP" "$TARGET"
  echo "setup-claude-permissions: wrote ${TARGET}"
else
  if ! have jq; then
    echo "setup-claude-permissions: ${TARGET} exists and jq is unavailable to merge." >&2
    echo "  Left untouched -- overwriting could discard settings that are not ours." >&2
    exit 0
  fi
  cp "$TARGET" "$TARGET.bak"
  jq --slurpfile new "$TMP" '
    .permissions.allow = (((.permissions.allow // []) + $new[0].permissions.allow) | unique) |
    .permissions.ask   = (((.permissions.ask   // []) + $new[0].permissions.ask)   | unique)
  ' "$TARGET.bak" > "$TMP.merged"
  eval "$VALIDATE" < "$TMP.merged"
  mv "$TMP.merged" "$TARGET"
  echo "setup-claude-permissions: merged into ${TARGET} (backup at ${TARGET}.bak)"
fi

if have jq; then
  jq -r '"setup-claude-permissions: \(.permissions.allow|length) allow, \(.permissions.ask|length) ask"' "$TARGET"
fi
