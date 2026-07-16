#!/usr/bin/env bash
#
# Create or update a paired workspace pin-bump MR that pins to $CI_COMMIT_SHA.
# Idempotent by design: same flexprice MR IID (or post-merge marker) always
# maps to the same workspace branch/MR pair, so re-runs update rather than
# duplicate.
#
# Called from flexprice's .gitlab-ci.yml. Fires in two modes:
#   MR mode:         $CI_MERGE_REQUEST_IID is set
#                    → BRANCH = pin-bump/flexprice-<IID>
#   Post-merge mode: push event on flexprice fam/main
#                    → BRANCH = pin-bump/flexprice-post-merge-<short-sha>
#
# Env vars (required):
#   WORKSPACE_ACCESS_TOKEN  GitLab token, api scope, Developer+ on workspace project.
#
# Env vars (provided by CI, with sane defaults):
#   CI_SERVER_URL           e.g. https://gitlab.famapp.in
#   WORKSPACE_PROJECT_PATH  e.g. backend/flexprice-workspace
#   WORKSPACE_TARGET_BRANCH e.g. fam/main
#   CI_COMMIT_SHA           the flexprice SHA to pin
#   CI_MERGE_REQUEST_IID    set for MR events; unset for push events
#   CI_PROJECT_URL          flexprice project URL (for cross-link in MR body)
#
# Writes:
#   workspace-mr.env with WORKSPACE_PIN_BRANCH=<branch> for the trigger job.

set -euo pipefail

: "${WORKSPACE_ACCESS_TOKEN:?WORKSPACE_ACCESS_TOKEN not set — add as CI variable}"
: "${CI_SERVER_URL:?CI_SERVER_URL not set (should be provided by GitLab CI)}"
: "${WORKSPACE_PROJECT_PATH:?WORKSPACE_PROJECT_PATH not set}"
: "${WORKSPACE_TARGET_BRANCH:?WORKSPACE_TARGET_BRANCH not set}"
: "${CI_COMMIT_SHA:?CI_COMMIT_SHA not set}"

# URL-encode the workspace project path for API v4 path lookups.
WORKSPACE_PROJECT_ENC=$(printf '%s' "$WORKSPACE_PROJECT_PATH" | sed 's|/|%2F|g')
API="${CI_SERVER_URL}/api/v4/projects/${WORKSPACE_PROJECT_ENC}"
HDR="PRIVATE-TOKEN: ${WORKSPACE_ACCESS_TOKEN}"

# Deterministic branch name based on flexprice MR IID or post-merge marker.
if [ -n "${CI_MERGE_REQUEST_IID:-}" ]; then
  BRANCH="pin-bump/flexprice-${CI_MERGE_REQUEST_IID}"
  MODE="MR"
  SOURCE_REF_DESC="flexprice MR !${CI_MERGE_REQUEST_IID}"
else
  BRANCH="pin-bump/flexprice-post-merge-${CI_COMMIT_SHA:0:8}"
  MODE="POST-MERGE"
  SOURCE_REF_DESC="flexprice fam/main @ ${CI_COMMIT_SHA:0:8}"
fi

echo "mode: $MODE  branch: $BRANCH  pinning flexprice SHA: $CI_COMMIT_SHA"

# URL-encode the branch (has a slash).
BRANCH_ENC=$(printf '%s' "$BRANCH" | sed 's|/|%2F|g')

# ─── Step 1: ensure workspace branch exists at fam/main tip ──────────────────
BRANCH_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "$HDR" \
  "${API}/repository/branches/${BRANCH_ENC}")

if [ "$BRANCH_STATUS" = "404" ]; then
  echo "branch $BRANCH not found; creating from ${WORKSPACE_TARGET_BRANCH}"
  CREATE_RESP=$(curl -sS -X POST \
    -H "$HDR" \
    --data-urlencode "branch=${BRANCH}" \
    --data-urlencode "ref=${WORKSPACE_TARGET_BRANCH}" \
    "${API}/repository/branches")
  if ! echo "$CREATE_RESP" | jq -e '.name' >/dev/null 2>&1; then
    echo "error: branch creation failed:" >&2
    echo "$CREATE_RESP" | jq . >&2 || echo "$CREATE_RESP" >&2
    exit 1
  fi
elif [ "$BRANCH_STATUS" != "200" ]; then
  echo "error: unexpected status $BRANCH_STATUS checking branch" >&2
  exit 1
else
  echo "branch $BRANCH already exists; will update pin"
fi

# ─── Step 2: read current .gitmodules pin on the workspace branch ────────────
GITMODULES_RESP=$(curl -sS \
  -H "$HDR" \
  "${API}/repository/files/.gitmodules/raw?ref=${BRANCH_ENC}")

# Verify we got .gitmodules content (not an error JSON).
if echo "$GITMODULES_RESP" | jq -e '.message' >/dev/null 2>&1; then
  echo "error: could not read .gitmodules on $BRANCH:" >&2
  echo "$GITMODULES_RESP" | jq . >&2
  exit 1
fi

# ─── Step 3: read current submodule pin from workspace tree ──────────────────
# Submodule pointers are tree entries, not in .gitmodules content. Use the
# repository tree endpoint to get the pinned SHA for the flexprice path.
CURRENT_PIN=$(curl -sS \
  -H "$HDR" \
  "${API}/repository/tree?ref=${BRANCH_ENC}&path=&recursive=false" \
  | jq -r '.[] | select(.name == "flexprice") | .id')

if [ -z "$CURRENT_PIN" ] || [ "$CURRENT_PIN" = "null" ]; then
  echo "error: could not read current flexprice pin from workspace $BRANCH" >&2
  exit 1
fi

echo "current workspace pin: $CURRENT_PIN"
echo "new pin:               $CI_COMMIT_SHA"

# ─── Step 4: short-circuit if pin already matches ────────────────────────────
if [ "$CURRENT_PIN" = "$CI_COMMIT_SHA" ]; then
  echo "pin already matches — skipping commit"
else
  # ─── Step 5: commit pin bump via API ──────────────────────────────────────
  # The commits API doesn't support gitlink (mode 160000) actions directly.
  # We use the "chmod" + "content" workaround: submit a commit that updates the
  # submodule entry via a file action with a gitlink-typed target.
  #
  # NOTE: GitLab API's create-commit endpoint supports action type "update" on
  # existing files, but submodule pointer updates require the "action" field
  # with type "chmod" is NOT the right shape either. The correct shape is a
  # commit action with type "update" targeting the submodule *file entry* with
  # a content that is the raw SHA. GitLab treats this as a gitlink update when
  # the existing tree entry is mode 160000.
  #
  # If your GitLab instance requires a different shape (some versions),
  # fall back to a local git clone + push here.

  COMMIT_PAYLOAD=$(jq -n \
    --arg branch "$BRANCH" \
    --arg msg    "bump flexprice pin to ${CI_COMMIT_SHA:0:8} (${SOURCE_REF_DESC})" \
    --arg path   "flexprice" \
    --arg sha    "$CI_COMMIT_SHA" \
    '{
      branch:         $branch,
      commit_message: $msg,
      force:          true,
      actions: [
        {
          action:   "update",
          file_path: $path,
          content:   $sha
        }
      ]
    }')

  COMMIT_RESP=$(curl -sS -X POST \
    -H "$HDR" \
    -H "Content-Type: application/json" \
    --data "$COMMIT_PAYLOAD" \
    "${API}/repository/commits")

  if ! echo "$COMMIT_RESP" | jq -e '.id' >/dev/null 2>&1; then
    echo "error: commit failed. If the shape isn't accepted by this GitLab" >&2
    echo "       version, switch to the local git clone + push fallback." >&2
    echo "$COMMIT_RESP" | jq . >&2 || echo "$COMMIT_RESP" >&2
    exit 1
  fi
  echo "pin-bump commit created: $(echo "$COMMIT_RESP" | jq -r '.short_id')"
fi

# ─── Step 6: ensure open MR exists ───────────────────────────────────────────
MR_SEARCH=$(curl -sS \
  -H "$HDR" \
  "${API}/merge_requests?source_branch=${BRANCH_ENC}&state=opened")

MR_IID=$(echo "$MR_SEARCH" | jq -r '.[0].iid // empty')
MR_URL=$(echo "$MR_SEARCH" | jq -r '.[0].web_url // empty')

if [ -z "$MR_IID" ]; then
  echo "no open MR for $BRANCH; creating"
  MR_TITLE="[auto] pin bump: ${SOURCE_REF_DESC}"
  MR_DESC="Automated pin bump from ${SOURCE_REF_DESC}.

Source: ${CI_PROJECT_URL:-flexprice} @ \`${CI_COMMIT_SHA:0:8}\`
Branch: \`${BRANCH}\`

This MR was created and is kept in sync by flexprice CI. Do not push to \`${BRANCH}\` manually."

  MR_CREATE_PAYLOAD=$(jq -n \
    --arg source "$BRANCH" \
    --arg target "$WORKSPACE_TARGET_BRANCH" \
    --arg title  "$MR_TITLE" \
    --arg desc   "$MR_DESC" \
    '{
      source_branch: $source,
      target_branch: $target,
      title:         $title,
      description:   $desc,
      remove_source_branch: true
    }')

  MR_CREATE_RESP=$(curl -sS -X POST \
    -H "$HDR" \
    -H "Content-Type: application/json" \
    --data "$MR_CREATE_PAYLOAD" \
    "${API}/merge_requests")

  if ! echo "$MR_CREATE_RESP" | jq -e '.iid' >/dev/null 2>&1; then
    echo "error: MR creation failed:" >&2
    echo "$MR_CREATE_RESP" | jq . >&2 || echo "$MR_CREATE_RESP" >&2
    exit 1
  fi

  MR_IID=$(echo "$MR_CREATE_RESP" | jq -r '.iid')
  MR_URL=$(echo "$MR_CREATE_RESP" | jq -r '.web_url')
  echo "created workspace MR !${MR_IID}: $MR_URL"
else
  echo "workspace MR already open: !${MR_IID} — $MR_URL"
fi

# ─── Step 7: export branch name for the trigger job ──────────────────────────
echo "WORKSPACE_PIN_BRANCH=${BRANCH}" > workspace-mr.env
echo "wrote workspace-mr.env: WORKSPACE_PIN_BRANCH=${BRANCH}"
