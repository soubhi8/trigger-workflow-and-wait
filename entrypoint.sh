#!/usr/bin/env bash
set -e

usage_docs() {
  echo ""
  echo "You can use this Github Action with:"
  echo "- uses: soubhi8/trigger-workflow-and-wait"
  echo "  with:"
  echo "    owner: <target-owner>"
  echo "    repo: <target-repo>"
  echo "    github_token: \${{ secrets.GITHUB_PERSONAL_ACCESS_TOKEN }}"
  echo "    workflow_file_name: main.yaml"
}
GITHUB_API_URL="${API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${SERVER_URL:-https://github.com}"
NOT_FOUND_RETRIES=0

validate_args() {
  wait_interval=10 # Waits for 10 seconds
  if [ "${INPUT_WAIT_INTERVAL}" ]
  then
    wait_interval=${INPUT_WAIT_INTERVAL}
  fi

  propagate_failure=true
  if [ -n "${INPUT_PROPAGATE_FAILURE}" ]
  then
    propagate_failure=${INPUT_PROPAGATE_FAILURE}
  fi

  trigger_workflow=true
  if [ -n "${INPUT_TRIGGER_WORKFLOW}" ]
  then
    trigger_workflow=${INPUT_TRIGGER_WORKFLOW}
  fi

  wait_workflow=true
  if [ -n "${INPUT_WAIT_WORKFLOW}" ]
  then
    wait_workflow=${INPUT_WAIT_WORKFLOW}
  fi

  if [ -z "${INPUT_OWNER}" ]
  then
    echo "Error: Owner is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_REPO}" ]
  then
    echo "Error: Repo is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_GITHUB_TOKEN}" ]
  then
    echo "Error: Github token is required. You can head over settings and"
    echo "under developer, you can create a personal access tokens. The"
    echo "token requires repo access."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_WORKFLOW_FILE_NAME}" ]
  then
    echo "Error: Workflow File Name is required"
    usage_docs
    exit 1
  fi

  client_payload=$(echo '{}' | jq -c)
  if [ "${INPUT_CLIENT_PAYLOAD}" ]
  then
    client_payload=$(echo "${INPUT_CLIENT_PAYLOAD}" | jq -c)
  fi

  ref="main"
  if [ "$INPUT_REF" ]
  then
    ref="${INPUT_REF}"
  fi
}

lets_wait() {
  local interval=${1:-$wait_interval}
  echo >&2 "Sleeping for $interval seconds"
  sleep "$interval"
}

api() {
  path=$1; shift
  local curl_exit_code
  if response=$(curl --fail-with-body -sSL \
      "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/$path" \
      -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github.v3+json' \
      -H 'Content-Type: application/json' \
      "$@")
  then
    echo "$response"
  else
    curl_exit_code=$?
    echo >&2 "api failed:"
    echo >&2 "path: $path"
    echo >&2 "response: $response"
    # Retry on transient curl errors (DNS, connection, timeout)
    # 6=DNS, 7=connection refused, 28=timeout, 35=SSL connect, 56=recv error
    if [[ $curl_exit_code -eq 6 || $curl_exit_code -eq 7 || $curl_exit_code -eq 28 || $curl_exit_code -eq 35 || $curl_exit_code -eq 56 ]]; then
      echo "{}"
      echo >&2 "Transient network error (curl exit code $curl_exit_code) - trying again"
    elif [[ "$response" == *'"Server Error"'* ]]; then
      echo "{}"
      echo >&2 "Server error - trying again"
    elif [ $NOT_FOUND_RETRIES -lt 3 ] && [[ "$response" == *'"Not Found"'* ]]; then
      echo "$response"
      NOT_FOUND_RETRIES=$((NOT_FOUND_RETRIES + 1))
      echo >&2 "Not found (attempt $NOT_FOUND_RETRIES) - trying again"
    else
      exit 1
    fi
  fi
}


# Return the ids of the most recent workflow runs, optionally filtered by user
get_workflow_runs() {
  since=${1:?}

  query="event=workflow_dispatch&created=>=$since${INPUT_GITHUB_USER+&actor=}${INPUT_GITHUB_USER}&per_page=100"

  echo "Getting workflow runs using query: ${query}" >&2

  api "workflows/${INPUT_WORKFLOW_FILE_NAME}/runs?${query}" |
  jq -r '.workflow_runs[].id' |
  sort # Sort to ensure repeatable order, and lexicographically for compatibility with join
}

trigger_workflow() {
  START_TIME=$(date +%s)
  SINCE=$(date -u -Iseconds -d "@$((START_TIME - 120))") # Two minutes ago, to overcome clock skew

  OLD_RUNS=$(get_workflow_runs "$SINCE")

  echo >&2 "Triggering workflow:"
  echo >&2 "  workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches"
  echo >&2 "  {\"ref\":\"${ref}\",\"inputs\":${client_payload}}"

  dispatch_response=$(api "workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches" \
    --data "{\"ref\":\"${ref}\",\"inputs\":${client_payload}}")

  # Check if the response contains workflow_run_id (new GitHub API behavior)
  workflow_run_id=$(echo "$dispatch_response" | jq -r '.workflow_run_id // empty')

  if [ -n "$workflow_run_id" ]; then
    echo >&2 "Workflow run ID returned directly: $workflow_run_id"
    echo "$workflow_run_id"
    return
  fi

  # Fall back to polling approach (old behavior)
  echo >&2 "No workflow_run_id in response, falling back to polling"
  NEW_RUNS=$OLD_RUNS
  while [ "$NEW_RUNS" = "$OLD_RUNS" ]
  do
    lets_wait
    NEW_RUNS=$(get_workflow_runs "$SINCE")
  done

  # Return new run ids
  join -v2 <(echo "$OLD_RUNS") <(echo "$NEW_RUNS")
}

comment_downstream_link() {
  if response=$(curl --fail-with-body -sSL -X POST \
      "${INPUT_COMMENT_DOWNSTREAM_URL}" \
      -H "Authorization: Bearer ${INPUT_COMMENT_GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github.v3+json' \
      -d "{\"body\": \"Running downstream job at $1\"}")
  then
    echo "$response"
  else
    echo >&2 "failed to comment to ${INPUT_COMMENT_DOWNSTREAM_URL}:"
  fi
}

wait_for_workflow_to_finish() {
  last_workflow_id=${1:?}
  last_workflow_url="${GITHUB_SERVER_URL}/${INPUT_OWNER}/${INPUT_REPO}/actions/runs/${last_workflow_id}"

  echo "Waiting for workflow to finish:"
  echo "The workflow id is [${last_workflow_id}]."
  echo "The workflow logs can be found at ${last_workflow_url}"
  echo "workflow_id=${last_workflow_id}" >> $GITHUB_OUTPUT
  echo "workflow_url=${last_workflow_url}" >> $GITHUB_OUTPUT
  echo ""

  if [ -n "${INPUT_COMMENT_DOWNSTREAM_URL}" ]; then
    comment_downstream_link ${last_workflow_url}
  fi

  conclusion=null
  status=

  while [[ "${conclusion}" == "null" && "${status}" != "completed" ]]
  do
    lets_wait

    workflow=$(api "runs/$last_workflow_id")
    conclusion=$(echo "${workflow}" | jq -r '.conclusion')
    status=$(echo "${workflow}" | jq -r '.status')

    echo "Checking conclusion [${conclusion}]"
    echo "Checking status [${status}]"
    echo "conclusion=${conclusion}" >> $GITHUB_OUTPUT
  done

  if [[ "${conclusion}" == "success" && "${status}" == "completed" ]]
  then
    echo "Yes, success"
  else
    # Alternative "failure"
    echo "Conclusion is not success, it's [${conclusion}]."

    if [ "${propagate_failure}" = true ]
    then
      echo "Propagating failure to upstream job"
      exit 1
    fi
  fi
}

main() {
  validate_args

  if [ "${trigger_workflow}" = true ]
  then
    run_ids=$(trigger_workflow)
  else
    echo "Skipping triggering the workflow."
  fi

  if [ "${wait_workflow}" = true ]
  then
    for run_id in $run_ids
    do
      wait_for_workflow_to_finish "$run_id"
    done
  else
    echo "Skipping waiting for workflow."
  fi
}

main
