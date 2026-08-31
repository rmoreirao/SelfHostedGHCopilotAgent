#!/usr/bin/env bash
set -euo pipefail

required_variables=(
  AZURE_CLIENT_ID
  AZURE_TENANT_ID
  AZURE_FEDERATED_TOKEN_FILE
  VALIDATION_KEY_VAULT_URL
  VALIDATION_SECRET_NAME
  VALIDATION_EXPECTED_VALUE
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "::error::Required environment variable ${variable} is not set."
    exit 1
  fi
done

for command_name in curl jq getent; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "::error::Required command ${command_name} is unavailable."
    exit 1
  fi
done

vault_host="${VALIDATION_KEY_VAULT_URL#https://}"
vault_host="${vault_host%%/*}"
vault_ip="$(getent ahostsv4 "${vault_host}" | awk 'NR == 1 { print $1 }')"
if [[ ! "${vault_ip}" =~ ^10\.42\.5\. ]]; then
  echo "::error::${vault_host} resolved to ${vault_ip:-nothing}, not the private endpoint subnet."
  exit 1
fi

federated_token="$(<"${AZURE_FEDERATED_TOKEN_FILE}")"
token_response="$(
  curl --silent --show-error --fail-with-body \
    --request POST \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
    --data-urlencode "scope=https://vault.azure.net/.default" \
    --data-urlencode "client_assertion=${federated_token}" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "grant_type=client_credentials" \
    "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token"
)"
unset federated_token

access_token="$(jq -er '.access_token' <<<"${token_response}")"
unset token_response

secret_response="$(
  curl --silent --show-error --fail-with-body \
    --header "Authorization: Bearer ${access_token}" \
    "${VALIDATION_KEY_VAULT_URL%/}/secrets/${VALIDATION_SECRET_NAME}?api-version=7.4"
)"
unset access_token

actual_value="$(jq -er '.value' <<<"${secret_response}")"
unset secret_response

if [[ "${actual_value}" != "${VALIDATION_EXPECTED_VALUE}" ]]; then
  echo "::error::The private Key Vault marker did not match the expected value."
  exit 1
fi

echo "PRIVATE_ACCESS_VALIDATED=${vault_host}@${vault_ip}"
