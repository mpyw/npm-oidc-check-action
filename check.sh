#!/usr/bin/env bash
#
# Check npm trusted publishing for the running workflow, and publish nothing.
#
# For each package, exchange the GitHub OIDC token for an npm token, the way
# `npm publish` does before it uploads (npm/cli lib/utils/oidc.js). The
# exchange succeeds only when a trusted publisher on the package matches this
# run. The npm token is masked and thrown away.
#
# `npm publish --dry-run` is not used. It does run the exchange, but a failed
# exchange is only a verbose log line, and the dry run still succeeds.
#
# Inputs (from action.yml): INPUT_PACKAGES, INPUT_REGISTRY.
set -euo pipefail

registry="${INPUT_REGISTRY%/}"
# npm builds the audience from the registry hostname alone.
host="$(sed -E 's#^[A-Za-z]+://##; s#[/:].*$##' <<<"$registry")"
audience="npm:${host}"

# Commas and any whitespace separate the names.
read -r -a packages <<<"$(tr ',\n\r\t' '    ' <<<"$INPUT_PACKAGES")"
if [[ ${#packages[@]} -eq 0 ]]; then
  echo "::error::No packages given. Set the 'packages' input."
  exit 1
fi

# Names go into a URL path, so anything outside npm's name characters is
# refused before a request is made.
name_re='^(@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*$'
for pkg in "${packages[@]}"; do
  if [[ ! "$pkg" =~ $name_re ]]; then
    echo "::error::'${pkg}' is not an npm package name"
    exit 1
  fi
done

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  echo "::error::No GitHub OIDC token is available. Give the job 'permissions: id-token: write'."
  exit 1
fi

id_token="$(
  curl -fsS -G \
    -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    --data-urlencode "audience=${audience}" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL" | jq -r '.value // empty'
)"
if [[ -z "$id_token" ]]; then
  echo "::error::GitHub returned no OIDC token"
  exit 1
fi
echo "::add-mask::${id_token}"

# npm matches the trusted publisher against these claims. workflow_ref names
# the workflow the run started from, which is the filename npm checks.
claims="$(jq -R 'split(".")[1] | gsub("-"; "+") | gsub("_"; "/")
  | . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson' <<<"$id_token")"
workflow_ref="$(jq -r '.workflow_ref // ""' <<<"$claims")"
environment="$(jq -r '.environment // ""' <<<"$claims")"
echo "repository:   $(jq -r '.repository // ""' <<<"$claims")"
echo "workflow_ref: ${workflow_ref}"
echo "environment:  ${environment:-(none)}"
echo "workflow-ref=${workflow_ref}" >>"$GITHUB_OUTPUT"

{
  echo "### npm trusted publishing"
  echo
  echo "Workflow: \`${workflow_ref%%@*}\`, environment: \`${environment:-(none)}\`"
  echo
  echo "| Package | Result |"
  echo "| --- | --- |"
} >>"$GITHUB_STEP_SUMMARY"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

failed=0
for pkg in "${packages[@]}"; do
  # npm escapes only the slash of a scoped name.
  url="${registry}/-/npm/v1/oidc/token/exchange/package/${pkg/\//%2f}"

  # Retry what may be transient: no response, or a server error.
  for attempt in 1 2 3; do
    code="$(curl -sS -o "$body" -w '%{http_code}' -X POST \
      -H "Authorization: Bearer ${id_token}" "$url" || true)"
    [[ "$code" == 000 || "$code" == 5* ]] || break
    [[ $attempt -lt 3 ]] && sleep $((attempt * 2))
  done

  token="$(jq -r '.token // empty' "$body" 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    echo "::add-mask::${token}"
    echo "OK  ${pkg}"
    echo "| \`${pkg}\` | ✅ |" >>"$GITHUB_STEP_SUMMARY"
  else
    # A failed exchange carries no token, so the body is safe to show.
    message="$(jq -r '.message // empty' "$body" 2>/dev/null || true)"
    [[ -n "$message" ]] || message="$(head -c 300 "$body")"
    echo "::error::${pkg}: HTTP ${code}: ${message}"
    echo "| \`${pkg}\` | ❌ HTTP ${code}: ${message} |" >>"$GITHUB_STEP_SUMMARY"
    failed=1
  fi
  unset token
done

exit "$failed"
