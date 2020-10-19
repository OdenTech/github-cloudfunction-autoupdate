#!/bin/bash

## Automatically update git-deployed cloudfunctions
##
## To my intense frustration, while you can deploy a google cloud function
## using a google cloud source repo as its source, and you can point it to
## a moveable function (a branch or a tag name) inside the repo, if the
## target of that ref is updated the cloud function does not detect the update
## and redeploy automatically.
##
## Worse yet, function instances are regional resources, so you can't just
## mash the "re-update" button -- you have to figure out which region(s) the
## function is currently deployed to and PATCH the running resource.
##
## So, this script. We do a number of things in order:
## 
## 1. Get a list of all deployed cloudfunctions in all regions, sort them
##    into an associative array of funcname->region[,region...]
##
## 2. Get the list of functions we manage in this repo, assumed to be
##    the list of directory names in $FUNCTIONS_DIR/
##
## 3. For each function we manage in this repo, if we previously found
##    a corresponding function deployed in step 1, then for each region
##    in which we found it running:
##
##    a. Pull down the JSON document representing the current function state
##
##    b. PATCH that document back up to the google API, and set the 'updateMask'
##       parameter to the sourceRepository.url field, which tells google that
##       it needs to re-resolve which git SHA the ref name points at
##
##    c. Get the operation ID returned by the PATCH API
##
## 4. Wait for all PATCH operations to complete and flag any errors.

set -e -o pipefail

DESTINATION_BRANCH="$(basename "${GITHUB_REF}")"

# we really need some less fragile way to establish this mapping
case "${DESTINATION_BRANCH}" in
  master)
    PROJECT_ID=oden-production
    GOOGLE_CREDENTIALS="${GOOGLE_CREDENTIALS_ODEN_PRODUCTION}"
    ;;
  *)
    PROJECT_ID=oden-qa
    GOOGLE_CREDENTIALS="${GOOGLE_CREDENTIALS_ODEN_QA}"
    ;;
esac

CLIENT_EMAIL="$(jq -r .client_email <<< "${GOOGLE_CREDENTIALS}")"
echo "${GOOGLE_CREDENTIALS}" > /tmp/creds.json
/google-cloud-sdk/bin/gcloud auth activate-service-account "${CLIENT_EMAIL}" --key-file=/tmp/creds.json

FUNCTIONS_DIR="${FUNCTIONS_DIR:-functions}"

cd "${FUNCTIONS_DIR}"
FUNCDIRS=(*)
mapfile -t FUNCPATHS < <( gcloud functions list --format='get(name)' )

unset DEPLOYED_FUNCTIONS
declare -A DEPLOYED_FUNCTIONS
for path in "${FUNCPATHS[@]}"; do
  mapfile -td/ patharray <<<"${path}"
  funcname="${patharray[5]%?}" # have to strip a newline here
  location="${patharray[3]}"
  echo "function ${funcname} found in ${location}"
  if [ "${DEPLOYED_FUNCTIONS[${funcname}]}" ]; then
    DEPLOYED_FUNCTIONS["${funcname}"]+=",${location}"
  else
    DEPLOYED_FUNCTIONS["${funcname}"]="${location}"
  fi
done

ACCESS_TOKEN="$(gcloud auth print-access-token)"
OPERATIONS=()

# each subdir should match the name of a function, but we don't know what region its deployed to if any
for funcdir in "${FUNCDIRS[@]}"; do
  # functions are regional so the same name could exist in multiple regions
  if [ "${DEPLOYED_FUNCTIONS[$funcdir]}" ]; then
    mapfile -td, locations <<<"${DEPLOYED_FUNCTIONS[$funcdir]}"
    for location in "${locations[@]}"; do
      location="${location%?}" # strip newline
      echo "Checking deployment of function ${funcdir} in region ${location}"
      deployed_url="$(gcloud --project="${PROJECT_ID}" functions describe "${funcdir}" --region="${location}" --format='value(sourceRepository.deployedUrl)')"
      if [ -z "${deployed_url}" ]; then
        echo "Function ${funcdir} in region ${location} is not source-repo deployed; skipping..."
        continue
      fi
      readarray -td/ deployed_url <<<"$deployed_url"
      deployed_sha="${deployed_url[8]}"
      echo "Checking function ${funcdir} in location ${location} is at sha ${deployed_sha}"
      if [[ "${deployed_sha}" != "${GITHUB_SHA}" ]]; then
        # if our current rev has a diff to the deployed rev, we must redeploy
        if ! git diff --quiet "${deployed_sha}" -- "${funcdir}"; then
          echo "Function ${funcdir} differs from deployed SHA ${deployed_sha} in ${location}; redeploying"
          gcloud functions describe --region "${location}" "${funcdir}" --format=json | \
            jq -M 'del(.sourceRepository.deployedUrl)' > "/tmp/${funcdir}_request.json"
          RESPONSE="$(curl -fs \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -X PATCH \
            "https://cloudfunctions.googleapis.com/v1/projects/${PROJECT_ID}/locations/${location}/functions/${funcdir}?updateMask=sourceRepository.url" \
            -d "@/tmp/${funcdir}_request.json")"
          OPERATION="$(jq -r .name <<<"${RESPONSE}")"
          echo "Started rollout operation ${OPERATION}"
          OPERATIONS+=("${OPERATION}")
        else
          echo "No diff found for function ${funcdir} in region ${location}"
        fi
      else
        echo "Function ${funcdir} already deployed at my sha ${GITHUB_SHA} in ${location}"
      fi
    done
  else
    echo "Function dir ${funcdir} does not correspond to a deployed function"
  fi
done

ACCESS_TOKEN="$(gcloud auth print-access-token)"
for operation in "${OPERATIONS[@]}"; do
  STATUS='{"done": false}'
  while [[ "$(jq -r .done <<<"${STATUS}")" != "true" ]]; do
    STATUS="$(curl -s \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      "https://cloudfunctions.googleapis.com/v1/${operation}")"
    echo "Sleeping 5 seconds waiting for operation ${operation} to complete"
    sleep 5
  done
  if [[ "$(jq -r .error <<<"${STATUS}")" != "null" ]]; then
    echo "Operation ${operation} failed: ${STATUS}"
    FAILED=true
  fi
done

if [[ "${FAILED}" ]]; then
  echo "One or more rollouts failed; see above for details"
  exit 1
fi

echo "All done! ✨🍰✨"
