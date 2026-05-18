# Auto-Grow Azure Files (Provisioned v2)

Automatically grows the quota of an Azure Files **Provisioned v2** share when used capacity crosses a configurable threshold. Designed for FSLogix profile workloads where data grows monotonically and downtime from a full share is unacceptable.

Email notifications are sent through **Azure Communication Services Email** — no Microsoft Graph, no tenant admin consent, no mailbox in your tenant required.

---

## What gets deployed

```
┌─────────────────────────────────────────────────────────────┐
│  Azure Automation Account                                   │
│  ├─ System-Assigned Managed Identity                        │
│  ├─ Modules (PowerShell 7.2): Az.Accounts, Az.Storage       │
│  ├─ Runbook: Grow-FslogixShare                              │
│  └─ Schedule: every 15 / 30 / 60 min                        │
└─────────────────────────────────────────────────────────────┘
        │                                       │
        │  Storage Account Contributor          │  Contributor (ACS only)
        ▼                                       ▼
┌────────────────────────────┐   ┌────────────────────────────────┐
│  Target Storage Account    │   │  Azure Communication Services  │
│  └─ File share (v2)        │   │  └─ Email Service              │
│     quota grows on demand  │   │     (Azure Managed Domain)     │
└────────────────────────────┘   └────────────────────────────────┘
```

---

## Prerequisites

- An Azure subscription where you have **Contributor** rights (no Global Admin needed).
- A target storage account of kind **FileStorage** with **PremiumV2** or **StandardV2** SKU, and a Provisioned v2 file share on it.
- An email address to receive notifications (can be internal, external, gmail, anything).

---

## Deploy in 3 minutes (Cloud Shell)

1. Open [Azure Cloud Shell](https://shell.azure.com) (Bash).
2. Download the three files from this repo into your Cloud Shell home directory:
   ```bash
   curl -O https://raw.githubusercontent.com/<your-org>/<your-repo>/main/main.bicep
   curl -O https://raw.githubusercontent.com/<your-org>/<your-repo>/main/Grow-FslogixShare.ps1
   curl -O https://raw.githubusercontent.com/<your-org>/<your-repo>/main/deploy-cloudshell.sh
   chmod +x deploy-cloudshell.sh
   ```
3. Run the script:
   ```bash
   ./deploy-cloudshell.sh
   ```
4. Answer the prompts (subscription, RG, target storage account, threshold, growth factor, etc.).
5. Wait ~3-5 min for the Bicep deploy and another ~10-15 min for the Az modules to finish importing in the Automation Account.

That's it. The runbook will trigger on the schedule you picked.

---

## How it works

The runbook reads the share's used capacity vs provisioned quota every N minutes. When usage crosses `ThresholdPercent`:

- It computes `newQuota = ceil(currentQuota × GrowthFactor)`, capped at `MaxQuotaGiB`.
- It calls `Update-AzRmStorageShare` to raise the quota.
- It sends an HTML email summarizing the change.

When the share has already reached `MaxQuotaGiB`, the runbook stops and sends a **high-importance** "action required" email listing the two possible remediations: raise the cap, or clean up files.

The runbook is **grow-only** — it never shrinks the quota. Azure also enforces a 24h cooldown before a decrease is allowed.

---

## Parameters reference

| Parameter | Default | Description |
|---|---|---|
| `thresholdPercent` | 80 | Trigger growth when used capacity reaches this % of provisioned (50-95). |
| `growthFactor` | 1.25 | Multiplier applied when growing (e.g. 1.25 = +25%). |
| `maxQuotaGiB` | 4096 | Hard cap. Runbook will stop growing past this. |
| `scheduleInterval` | PT30M | Run frequency. Allowed: `PT15M`, `PT30M`, `PT1H`. |
| `notificationEmail` | _(empty)_ | Recipient. Leave empty to skip ACS deployment and disable emails. |
| `acsDataLocation` | Europe | Data residency for the ACS resources. |

---

## Verifying the deployment

After the script completes:

1. **Automation Account → Modules** — `Az.Accounts` and `Az.Storage` should show **Available** (takes 10-15 min on first deploy).
2. **Automation Account → Runbooks → Grow-FslogixShare** — status **Published**.
3. **Automation Account → Schedules → AutoGrowSchedule** — enabled, with a `Grow-FslogixShare` job link.
4. **Target storage account → IAM** — the AA's managed identity has **Storage Account Contributor**.
5. **ACS resource → IAM** — the AA's managed identity has **Contributor**.

To force an immediate test run:

```bash
az automation runbook start \
  -g <your-aa-rg> \
  --automation-account-name <your-aa-name> \
  --name Grow-FslogixShare
```

The first email from the ACS Azure-Managed Domain may land in the spam folder — whitelist `DoNotReply@*.azurecomm.net` to avoid that.

---

## Gotchas

- **Module import is asynchronous.** Jobs run in the first ~10 minutes after deployment may fail with "module not found". Just wait.
- **ACS Managed Domain delay.** Right after deployment, the managed domain needs ~1-2 min to be fully provisioned. The first email send may fail; retry.
- **Sender address is `DoNotReply@<guid>.azurecomm.net`** by default. To get a clean `alerts@yourdomain.com`, add a verified custom domain in the ACS portal (10 min of DNS records) and update `AcsSenderAddress` on the `jobSchedule`.
- **Cross-subscription target storage** is not supported by this template. The target SA must live in the same subscription as the Automation Account.
- **Grow-only.** The runbook never decreases quota. Azure enforces a 24h cooldown before a decrease, and decreases below current used space are rejected.

---

## Tearing it down

```bash
az group delete --name <your-aa-rg> --yes
```

Everything in the RG is removed: Automation Account, runbook, schedule, role assignments, and the ACS + Email Service resources.

---

## License

MIT.
