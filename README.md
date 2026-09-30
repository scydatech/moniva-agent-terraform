# Moniva Transaction Investigation Agent

An internal AI agent that helps Moniva operations staff investigate transaction issues.

A staff member gives the agent a transaction reference or account ID and describes the problem, for example *"Customer says she was debited NGN 150,000 but the transfer failed."* The agent works out what it needs to check, looks up the transaction, the account and related transactions, finds the applicable operational procedure, and prepares a structured case summary with the evidence, findings and recommended next steps. Staff can ask follow-up questions on the same investigation.

Typical cases:

- **Failed transfer, customer debited:** checks the debit, failure reason, reversal status and the reversal timeline.
- **Duplicate debit:** finds matching payments to the same counterparty close in time.
- **Suspicious activity:** reviews recent security events, new beneficiaries and rapid transfers, and prepares a fraud escalation summary.

> **The agent investigates; staff decide.** It has read-only access. It cannot reverse, refund, freeze or change anything, and it marks every consequential action as *Requires staff authorization*, naming the approver from Moniva's authorization matrix.

---

## How it works

```
Staff ─► API Gateway (Cognito sign-in) ─► API Lambda ─► creates investigation (DynamoDB), returns 202
                                               └──► Worker Lambda ─► AgentCore Runtime: investigation agent
                                                                        ├─ Input guardrail: block action requests
                                                                        ├─ AgentCore Memory: earlier turns of this case
                                                                        ├─ Claude Sonnet 4.5: plan, call tools, write summary
                                                                        │    ├─ AgentCore Gateway (MCP, IAM) ─► Tools Lambda ─► transactions / accounts
                                                                        │    └─ Knowledge Base ─► approved procedures
                                                                        └─ Output guardrail: mask sensitive data
Staff ◄── GET /v1/investigations/{id}: case summary + evidence

Approved procedures ─► S3 ─► Lambda ─► Knowledge Base ─► Titan Embeddings ─► S3 Vectors
```

Investigations run in the background because they can take longer than an API request allows; the client polls for the result.

---

## AWS services and why they are used

| Service | Why it is used |
|---|---|
| **Amazon Bedrock AgentCore Runtime** | Runs the investigation agent in an isolated, managed environment with one session per investigation. Deployed directly from code, with no servers or containers to manage. |
| **Amazon Bedrock AgentCore Gateway** | Exposes the transaction and account lookups to the agent as tools over MCP. Only the agent's role can call it (IAM), and it calls the tools Lambda with its own role. |
| **Amazon Bedrock AgentCore Identity** | Gives the agent and the gateway their own workload identities, so each can only reach the resources it is authorized for. |
| **Amazon Bedrock AgentCore Memory** | Keeps the conversation of each investigation so staff can ask follow-up questions without repeating context. Events expire automatically. |
| **Amazon Bedrock – Claude Sonnet 4.5** | Plans the investigation, decides which tools to call, reasons over the evidence and writes the case summary. |
| **Amazon Bedrock Knowledge Bases** | Searches Moniva's approved operational procedures so recommendations follow Moniva's own rules. |
| **Amazon Titan Text Embeddings V2** and **Amazon S3 Vectors** | Make the procedures searchable by meaning, at low cost. |
| **Amazon Bedrock Guardrails** | Blocks requests for the agent to take account or payment actions, filters harmful content and prompt attacks, and masks sensitive data in summaries. |
| **AWS Lambda** | Runs the read-only tools (the controlled data layer), the API, the background investigation worker and the document sync. |
| **Amazon DynamoDB** | Holds sample transaction and account data for the tools, and the investigation cases with their summaries and evidence. |
| **Amazon API Gateway** | Provides the secure API and rejects requests without a valid sign-in token. |
| **Amazon Cognito** | Staff sign-in with mandatory MFA; roles (investigators, supervisors, admins) control who can view which investigations. |
| **Amazon S3** | Stores the approved procedure documents and the agent's code package. |
| **Amazon EventBridge** | Runs an hourly backstop sync of the procedures knowledge base. |
| **AWS KMS** | Encrypts documents, tables, logs and audit records with a Moniva-managed key. |
| **AWS IAM** | Gives every component only the permissions it needs; the tools can only read. |
| **Amazon CloudWatch**, **Amazon SNS**, **AWS X-Ray** | Logs, alarms (failed investigations, blocked requests, errors) with email alerts, and request tracing. |
| **AWS CloudTrail** | Records every read of transaction and account data, procedure documents and knowledge base searches. |

All resources are in **eu-central-1 (Frankfurt)**, and every resource name ends in the client name (for example `transaction-tools-dev-moniva`).

---

## Project structure

```
moniva-agent-terraform/
├── *.tf                    # Terraform infrastructure
├── agent/                  # Investigation agent (runs on AgentCore Runtime)
├── lambda_src/
│   ├── tools/              # Read-only transaction and account tools (behind the gateway)
│   ├── api/                # Investigations API
│   ├── worker/             # Runs each investigation turn on the agent
│   └── ingestion/          # Knowledge base sync
├── scripts/
│   ├── build_agent.sh      # Packages the agent for Linux arm64 (run automatically by Terraform)
│   └── seed_sample_data.sh # Loads sample accounts and transactions
└── sample_data/documents/  # Sample operational procedures
```

---

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # set environment and alarm email
terraform init
terraform apply
bash scripts/seed_sample_data.sh               # sample accounts and transactions
aws s3 cp sample_data/documents/ s3://$(terraform output -raw procedures_bucket)/approved/ --recursive
```

Requires Terraform 1.10+, the AWS CLI, `jq`, and Python 3 with pip (`sudo apt install -y python3-pip jq`) to package the agent. Claude Sonnet 4.5 must be enabled in Amazon Bedrock for the account.
