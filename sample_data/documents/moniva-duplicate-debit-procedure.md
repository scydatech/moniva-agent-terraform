# Moniva Procedure: Duplicate Debit Investigation

Document ID: MNV-OPS-104 | Version: 1.3 | Owner: Head of Operations | Effective: 1 August 2026
Classification: Internal | SAMPLE DOCUMENT FOR SYSTEM TESTING - FICTIONAL CONTENT

## 1. When this procedure applies
A customer reports being charged more than once for a single payment (bill payment, merchant payment, airtime or transfer).

## 2. What counts as a suspected duplicate
Two or more successful debits on the same account with:
- the same amount, and
- the same counterparty (biller, merchant or beneficiary account), and
- no more than 10 minutes apart.

Debits that meet these criteria are "suspected duplicates". Payments further apart, or with different amounts, are treated as separate payments unless the customer provides evidence otherwise.

## 3. Investigation steps
1. Look up the reported transaction and search for similar transactions on the account (same amount and counterparty) within 60 minutes either side.
2. Confirm the status of each matching transaction. Only successful debits can be duplicates.
3. For bill payments, check whether the biller token or receipt was issued once or twice. A second token means the customer received value twice and it is not a duplicate.
4. Record the references, timestamps and statuses of all matching transactions.

## 4. Resolution
- If the duplicate is confirmed, a refund of the duplicate amount must be raised.
- Refunds up to NGN 100,000 require authorization by an Operations Supervisor.
- Refunds above NGN 100,000 require authorization by the Head of Operations.
- Where the biller or merchant must return the funds, open a recall request with the Settlements team.

## 5. Timelines
Duplicate debit complaints must be resolved within 72 hours. Keep the customer informed every 24 hours until resolution.
