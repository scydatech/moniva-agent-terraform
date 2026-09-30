# Moniva Procedure: Failed Transfer with Customer Debited

Document ID: MNV-OPS-101 | Version: 2.0 | Owner: Head of Operations | Effective: 1 August 2026
Classification: Internal | SAMPLE DOCUMENT FOR SYSTEM TESTING - FICTIONAL CONTENT

## 1. When this procedure applies
A customer reports that an outward transfer failed or the beneficiary did not receive the funds, but the customer's account was debited.

## 2. Investigation steps
1. Look up the transaction by reference. Record the amount, status, debit status, failure reason, NIP session ID and timestamp.
2. Confirm the debit on the customer's account and check whether a reversal has already been posted (reversal status and reversal reference).
3. Check the failure reason. Timeouts (NIP response codes 91 and 96) and "beneficiary bank unavailable" are treated as uncertain outcomes until a Transaction Status Query (TSQ) confirms the final status.
4. Check the customer's other transactions to the same beneficiary in the previous 24 hours to rule out a successful retry.
5. Record all findings in the case summary.

## 3. Automatic reversal window
Failed outward transfers are reversed automatically by the payment switch within 24 hours of the transaction time. Do not raise a manual reversal inside this window unless a TSQ has confirmed the transfer failed.

## 4. Manual reversal
If the transfer failed and no reversal has been posted after 24 hours, a manual reversal must be raised.
- Up to NGN 500,000: requires authorization by an Operations Supervisor.
- Above NGN 500,000: requires authorization by the Head of Operations.
Investigators must not promise the customer a reversal before it is authorized.

## 5. Customer communication
- Acknowledge the complaint within 1 hour during business hours.
- Give the customer the case reference and the expected resolution time.
- Resolve and respond within 48 hours of the complaint. If the case needs the beneficiary bank, inform the customer and escalate to the Settlements team.

## 6. Escalation
Escalate to the Settlements team if the TSQ shows the beneficiary bank received the funds but did not credit the beneficiary, or if the TSQ result is still pending after 24 hours.
