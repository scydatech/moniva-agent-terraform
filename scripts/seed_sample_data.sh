#!/usr/bin/env bash
# Loads sample Moniva accounts and transactions for testing (fictional data).
# Timestamps are relative to today, so the "last N days" tools always find them.
# Run from the Terraform folder after `terraform apply`:  bash scripts/seed_sample_data.sh
set -euo pipefail

command -v jq >/dev/null || { echo "jq is required: sudo apt install -y jq" >&2; exit 1; }

TXN_TABLE=$(terraform output -raw transactions_table)
ACC_TABLE=$(terraform output -raw accounts_table)
ts() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }

put() { aws dynamodb put-item --table-name "$1" --item "$2" --no-cli-pager >/dev/null; }
# Items are built into a variable first so any jq error stops the script.

# ---------------------------------------------------------------- accounts
account() { # id name tier status daily_limit available ledger phone email flags_json events_json
  local item
  item="$(jq -nc \
    --arg id "$1" --arg name "$2" --arg tier "$3" --arg status "$4" --arg limit "$5" \
    --arg avail "$6" --arg ledger "$7" --arg phone "$8" --arg email "$9" \
    --argjson flags "${10}" --argjson events "${11}" --arg opened "$(ts '-400 days')" '{
      account_id: {S: $id}, account_name: {S: $name}, kyc_tier: {N: $tier}, status: {S: $status},
      daily_transfer_limit_ngn: {N: $limit}, available_balance_ngn: {N: $avail}, ledger_balance_ngn: {N: $ledger},
      phone: {S: $phone}, email: {S: $email}, opened_at: {S: $opened}, currency: {S: "NGN"},
      risk_flags: {L: [$flags[] | {S: .}]},
      recent_security_events: {L: [$events[] | {M: {type: {S: .type}, at: {S: .at}, detail: {S: .detail}}}]}
    }')"
  put "$ACC_TABLE" "$item"
}

account ACC-1001 "Adaeze Okafor" 3 ACTIVE 5000000 842500 842500 "+2348031234567" "adaeze.okafor@example.com" '[]' '[]'
account ACC-3003 "Chiamaka Eze" 3 ACTIVE 5000000 311200 311200 "+2348059876543" "chiamaka.eze@example.com" '[]' '[]'
account ACC-2002 "Tunde Bello" 2 ACTIVE 1000000 48300 48300 "+2348124455667" "tunde.bello@example.com" \
  '["new_device_24h", "password_reset_24h"]' \
  "$(jq -nc --arg a "$(ts '-1 day -3 hours')" --arg b "$(ts '-1 day -2 hours -40 minutes')" \
     '[{type:"new_device_login", at:$a, detail:"Android device first seen; location Lagos"},
       {type:"password_reset", at:$b, detail:"Reset via SMS OTP from new device"}]')"

# ---------------------------------------------------------------- transactions
txn() { # ref account timestamp type channel amount status cp_name cp_bank cp_account narration [extra_json]
  local extra="${12:-}"; [ -n "$extra" ] || extra="{}"
  local item
  item="$(jq -nc \
    --arg ref "$1" --arg acc "$2" --arg t "$3" --arg type "$4" --arg ch "$5" --arg amt "$6" --arg st "$7" \
    --arg cpn "$8" --arg cpb "$9" --arg cpa "${10}" --arg nar "${11}" --argjson extra "$extra" '{
      transaction_ref: {S: $ref}, account_id: {S: $acc}, timestamp: {S: $t}, type: {S: $type},
      channel: {S: $ch}, amount: {N: $amt}, currency: {S: "NGN"}, status: {S: $st},
      counterparty_name: {S: $cpn}, counterparty_bank: {S: $cpb}, counterparty_account: {S: $cpa},
      narration: {S: $nar}, fee: {N: "0"}
    } + ($extra | with_entries(.value = (if (.value|type) == "number" then {N: (.value|tostring)} else {S: (.value|tostring)} end)))')"
  put "$TXN_TABLE" "$item"
}

# Scenario A - failed transfer, customer debited, not yet reversed (ACC-1001)
txn TXN-A-0001 ACC-1001 "$(ts '-2 days -5 hours')" transfer_out mobile_app 150000 FAILED \
  "Emeka Stores Ltd" "Guaranty Trust Bank" "0123456789" "Payment for stock" \
  '{"debit_status":"DEBITED","reversal_status":"NOT_REVERSED","failure_reason":"Beneficiary bank timeout (NIP 91)","nip_session_id":"000013260928091412000000000001","settlement_status":"PENDING_TSQ"}'
txn TXN-A-0002 ACC-1001 "$(ts '-2 days -4 hours')" transfer_out mobile_app 20000 SUCCESSFUL \
  "Ngozi Adeyemi" "Access Bank" "0987654321" "Rent contribution" '{"debit_status":"DEBITED","settlement_status":"SETTLED"}'
txn TXN-A-0003 ACC-1001 "$(ts '-6 days')" wallet_topup bank_transfer 500000 SUCCESSFUL \
  "Adaeze Okafor" "Zenith Bank" "1122334455" "Top up" '{"settlement_status":"SETTLED"}'

# Scenario B - duplicate bill payment 90 seconds apart (ACC-3003)
txn TXN-B-0001 ACC-3003 "$(ts '-1 day -6 hours')" bill_payment mobile_app 25000 SUCCESSFUL \
  "Ikeja Electric" "Biller" "45012345678" "Prepaid meter 45012345678" '{"biller_token_issued":"YES","biller_receipt":"IE-778812"}'
txn TXN-B-0002 ACC-3003 "$(ts '-1 day -6 hours +90 seconds')" bill_payment mobile_app 25000 SUCCESSFUL \
  "Ikeja Electric" "Biller" "45012345678" "Prepaid meter 45012345678" '{"biller_token_issued":"NO","biller_receipt":"NONE"}'
txn TXN-B-0003 ACC-3003 "$(ts '-4 days')" airtime mobile_app 2000 SUCCESSFUL \
  "MTN Nigeria" "Biller" "08059876543" "Airtime" '{}'

# Scenario C - possible account takeover: new device + password reset, then rapid transfers to new beneficiaries (ACC-2002)
txn TXN-C-0001 ACC-2002 "$(ts '-1 day -2 hours -10 minutes')" transfer_out mobile_app 290000 SUCCESSFUL \
  "Musa Ibrahim" "Opay" "8011122233" "Transfer" '{"beneficiary_first_seen":"YES","settlement_status":"SETTLED"}'
txn TXN-C-0002 ACC-2002 "$(ts '-1 day -2 hours -2 minutes')" transfer_out mobile_app 295000 SUCCESSFUL \
  "Musa Ibrahim" "Opay" "8011122233" "Transfer" '{"beneficiary_first_seen":"NO","settlement_status":"SETTLED"}'
txn TXN-C-0003 ACC-2002 "$(ts '-1 day -1 hour -50 minutes')" transfer_out mobile_app 200000 SUCCESSFUL \
  "Blessing Nwosu" "Palmpay" "9022233344" "Transfer" '{"beneficiary_first_seen":"YES","settlement_status":"SETTLED"}'
txn TXN-C-0004 ACC-2002 "$(ts '-1 day -1 hour -41 minutes')" transfer_out mobile_app 165000 SUCCESSFUL \
  "Kelechi Obi" "Moniepoint" "5033344455" "Transfer" '{"beneficiary_first_seen":"YES","settlement_status":"SETTLED"}'
txn TXN-C-0005 ACC-2002 "$(ts '-9 days')" transfer_out mobile_app 15000 SUCCESSFUL \
  "Folake Bello" "First Bank" "3044455566" "Family support" '{"beneficiary_first_seen":"NO","settlement_status":"SETTLED"}'

echo "Loaded 3 accounts and 11 transactions into $ACC_TABLE and $TXN_TABLE."
echo "Try: TXN-A-0001 (failed transfer, debited), TXN-B-0002 (duplicate bill payment), ACC-2002 (possible account takeover)."
