#!/usr/bin/env bash
# Publish sibling files under assets/ to s3://platforma-cloudformation.
#
#   preview (CI):       CFN_PREFIX=pr/<version>  -> .../pr/<version>/assets/
#   release (helm CI):  CFN_PREFIX unset         -> .../assets/
#
# Does not upload cloudformation-eks-1-35.yaml. Preview YAML is written by
# the preview publish workflow under the same CFN_PREFIX. Production YAML
# is written only by the platforma-helm release workflow at the bucket root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ASSETS="${ROOT}/assets"
BUCKET="${CFN_BUCKET:-platforma-cloudformation}"
PUBLIC_HOST="https://${BUCKET}.s3.eu-central-1.amazonaws.com"

if [[ -n "${CFN_PREFIX:-}" ]]; then
  CFN_PREFIX="${CFN_PREFIX#/}"
  CFN_PREFIX="${CFN_PREFIX%/}"
  ASSETS_KEY="${CFN_PREFIX}/assets"
else
  ASSETS_KEY="assets"
fi

# PutObject-only IAM (preview CI policy) cannot s3 sync: sync lists the prefix.
upload_tree() {
  local src="$1" dest="$2"
  local file rel
  while IFS= read -r -d '' file; do
    rel="${file#"${src}/"}"
    aws s3 cp "${file}" "s3://${BUCKET}/${dest}/${rel}" --no-progress
  done < <(find "${src}" -type f \
    ! -path '*/.*' ! -path '*/__pycache__/*' -print0)
}

echo "uploading ${ASSETS}/ -> s3://${BUCKET}/${ASSETS_KEY}/"
upload_tree "${ASSETS}" "${ASSETS_KEY}"
echo "published assets at ${PUBLIC_HOST}/${ASSETS_KEY}"
