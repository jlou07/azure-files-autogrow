<#
.SYNOPSIS
    Auto-grow an Azure Files (Provisioned v2) share quota based on used capacity.

.DESCRIPTION
    Monitors a v2 file share's used capacity vs provisioned quota.
    Increases quota when usage exceeds a threshold. Designed for FSLogix workloads
    where profile data grows monotonically. Grow-only pattern: never decreases quota.

    Sends email notifications via Azure Communication Services (ACS) Email using
    the Automation Account's managed identity (Entra ID auth, no secrets).
    The MI must have Contributor on the ACS resource. Two events:
      - 'grow'        : sent after the runbook successfully increases the quota.
      - 'cap_reached' : sent when the hard cap (MaxQuotaGiB) is reached.

    Includes a -WhatIf switch for safe testing — logs the action it WOULD take
    without making any change.

.PARAMETER SubscriptionId
    The Azure subscription ID containing the storage account.

.PARAMETER ResourceGroupName
    Resource group of the storage account.

.PARAMETER StorageAccountName
    Storage account name (must be FileStorage kind with PremiumV2/StandardV2 SKU).

.PARAMETER FileShareName
    Name of the Provisioned v2 file share.

.PARAMETER ThresholdPercent
    Trigger growth when used capacity reaches this percentage of provisioned. Default 80.

.PARAMETER GrowthFactor
    Multiplier applied to current quota when growing. Default 1.25 (+25%).

.PARAMETER MaxQuotaGiB
    Hard cap to prevent runaway growth. Script will warn and stop if reached. Default 4096.

.PARAMETER NotificationEmail
    Recipient address for notifications. Can be ANY address (internal or external).
    Leave empty to disable email notifications.

.PARAMETER AcsEndpoint
    ACS Communication Services endpoint URL (e.g. https://my-acs.europe.communication.azure.com).
    Required when NotificationEmail is set.

.PARAMETER AcsSenderAddress
    Sender ("From") address provided by the ACS managed domain
    (e.g. DoNotReply@<guid>.azurecomm.net). Required when NotificationEmail is set.

.PARAMETER WhatIf
    Dry-run mode. Logs what would happen without changing anything. Use this for testing.

.NOTES
    Designed for Azure Automation Runbook with a Managed Identity that has:
      - "Storage Account Contributor" on the target storage account
      - "Contributor" on the ACS Communication Services resource (for email)

    Modules required: Az.Accounts, Az.Storage (import in Automation Account).

    Schedule recommendation: every 15-30 minutes.
#>

param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [string]$FileShareName,

    [ValidateRange(50, 95)]
    [int]$ThresholdPercent = 80,

    [ValidateRange(1.05, 2.0)]
    [double]$GrowthFactor = 1.25,

    [ValidateRange(32, 262144)]
    [int]$MaxQuotaGiB = 4096,

    [string]$NotificationEmail = '',

    [string]$AcsEndpoint = '',

    [string]$AcsSenderAddress = '',

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Output "[$ts] [$Level] $Message"
}

function Send-AcsMail {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$SenderAddress,
        [Parameter(Mandatory)][string]$ToAddress,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$BodyHtml,
        [string]$Importance = 'normal'
    )
    try {
        # Acquire an Entra ID token for the ACS resource
        $token = (Get-AzAccessToken -ResourceUrl 'https://communication.azure.com' -ErrorAction Stop).Token

        $payload = @{
            senderAddress = $SenderAddress
            content = @{
                subject = $Subject
                html    = $BodyHtml
            }
            recipients = @{
                to = @(
                    @{ address = $ToAddress }
                )
            }
            importance = $Importance
        } | ConvertTo-Json -Depth 8 -Compress

        $uri = "$($Endpoint.TrimEnd('/'))/emails:send?api-version=2023-03-31"
        Invoke-RestMethod -Method POST -Uri $uri `
            -Headers @{ Authorization = "Bearer $token" } `
            -ContentType 'application/json' `
            -Body $payload | Out-Null

        Write-Log "Email sent via ACS to $ToAddress ($Subject)" 'OK'
    }
    catch {
        Write-Log "Failed to send email via ACS: $($_.Exception.Message)" 'WARN'
    }
}

# --- Explicit module load (PS 7.2 Automation auto-loading is unreliable) ---
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Storage  -ErrorAction Stop

try {
    # --- Authenticate ---
    if ($env:AUTOMATION_ASSET_ACCOUNTID) {
        Write-Log "Authenticating with Automation managed identity"
        Connect-AzAccount -Identity | Out-Null
    } else {
        Write-Log "Running outside Automation — assuming current Az context"
        if (-not (Get-AzContext)) {
            throw "No Az context. Run Connect-AzAccount first."
        }
    }

    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

    # --- Validate notification config ---
    $emailEnabled = -not [string]::IsNullOrWhiteSpace($NotificationEmail)
    if ($emailEnabled -and (-not $AcsEndpoint -or -not $AcsSenderAddress)) {
        Write-Log "NotificationEmail is set but AcsEndpoint/AcsSenderAddress missing — emails disabled" 'WARN'
        $emailEnabled = $false
    }

    # --- Read current share state ---
    Write-Log "Reading share: $FileShareName in $StorageAccountName"
    $share = Get-AzRmStorageShare `
        -ResourceGroupName $ResourceGroupName `
        -StorageAccountName $StorageAccountName `
        -Name $FileShareName `
        -GetShareUsage

    $provisionedGiB = [int]$share.QuotaGiB
    $usedBytes      = [long]$share.ShareUsageBytes
    $usedGiB        = [math]::Round($usedBytes / 1GB, 2)
    $usagePercent   = [math]::Round(($usedGiB / $provisionedGiB) * 100, 1)

    Write-Log "Provisioned : $provisionedGiB GiB"
    Write-Log "Used        : $usedGiB GiB ($usagePercent%)"
    Write-Log "Threshold   : $ThresholdPercent%"

    $portalLink = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName/fileServices/default/shares/$FileShareName"

    # --- Decide ---
    if ($usagePercent -lt $ThresholdPercent) {
        Write-Log "Usage under threshold — no action needed."
        return
    }

    $newQuotaGiB = [int][math]::Ceiling($provisionedGiB * $GrowthFactor)

    if ($provisionedGiB -ge $MaxQuotaGiB) {
        Write-Log "Already at hard cap ($MaxQuotaGiB GiB). MANUAL INTERVENTION REQUIRED." 'WARN'

        if ($emailEnabled) {
            $capHtml = @"
<h2 style="color:#c00">&#x1F6A8; Action required &mdash; Auto-grow blocked</h2>
<p>The file share <b>$FileShareName</b> on storage account <b>$StorageAccountName</b> has reached its configured maximum quota. The auto-grow runbook can no longer increase the quota.</p>
<table cellpadding="6" style="border-collapse:collapse;border:1px solid #ccc">
  <tr><td><b>Current quota</b></td><td>$provisionedGiB GiB (= cap reached)</td></tr>
  <tr><td><b>Usage</b></td><td>$usedGiB GiB ($usagePercent %)</td></tr>
  <tr><td><b>Configured cap</b></td><td>$MaxQuotaGiB GiB</td></tr>
  <tr><td><b>Storage Account</b></td><td>$StorageAccountName</td></tr>
  <tr><td><b>Resource Group</b></td><td>$ResourceGroupName</td></tr>
</table>
<p><b>What to do:</b></p>
<ul>
  <li>Increase the <code>MaxQuotaGiB</code> parameter on the jobSchedule</li>
  <li>Or clean up files in the share to free up space</li>
</ul>
<p><a href="$portalLink">Open the share in the Azure portal &rarr;</a></p>
<p style="color:#888;font-size:11px">Sent by the <b>Grow-FslogixShare</b> runbook.</p>
"@
            Send-AcsMail -Endpoint $AcsEndpoint -SenderAddress $AcsSenderAddress `
                -ToAddress $NotificationEmail `
                -Subject "[ACTION REQUIRED] $FileShareName has reached its max quota ($MaxQuotaGiB GiB)" `
                -BodyHtml $capHtml `
                -Importance 'high'
        }
        return
    }

    if ($newQuotaGiB -gt $MaxQuotaGiB) {
        Write-Log "Growth capped at hard limit ($MaxQuotaGiB GiB)" 'WARN'
        $newQuotaGiB = $MaxQuotaGiB
    }

    Write-Log "Proposed new quota: $newQuotaGiB GiB (+$($newQuotaGiB - $provisionedGiB) GiB)"

    # --- Apply ---
    if ($WhatIf) {
        Write-Log "WhatIf mode — NO changes applied." 'DRYRUN'
        return
    }

    Update-AzRmStorageShare `
        -ResourceGroupName $ResourceGroupName `
        -StorageAccountName $StorageAccountName `
        -Name $FileShareName `
        -QuotaGiB $newQuotaGiB | Out-Null

    Write-Log "SUCCESS — quota updated from $provisionedGiB GiB to $newQuotaGiB GiB" 'OK'

    if ($emailEnabled) {
        $growHtml = @"
<h2 style="color:#0a0">&#x2705; File share automatically grown</h2>
<p>The auto-grow runbook has increased the quota on file share <b>$FileShareName</b>.</p>
<table cellpadding="6" style="border-collapse:collapse;border:1px solid #ccc">
  <tr><td><b>Previous quota</b></td><td>$provisionedGiB GiB</td></tr>
  <tr><td><b>New quota</b></td><td>$newQuotaGiB GiB (+$($newQuotaGiB - $provisionedGiB) GiB)</td></tr>
  <tr><td><b>Usage at run time</b></td><td>$usedGiB GiB ($usagePercent %)</td></tr>
  <tr><td><b>Storage Account</b></td><td>$StorageAccountName</td></tr>
  <tr><td><b>Resource Group</b></td><td>$ResourceGroupName</td></tr>
</table>
<p>No action required. This is just for your information.</p>
<p><a href="$portalLink">Open the share in the Azure portal &rarr;</a></p>
<p style="color:#888;font-size:11px">Sent by the <b>Grow-FslogixShare</b> runbook.</p>
"@
        Send-AcsMail -Endpoint $AcsEndpoint -SenderAddress $AcsSenderAddress `
            -ToAddress $NotificationEmail `
            -Subject "[Auto-grow] $FileShareName : $provisionedGiB -> $newQuotaGiB GiB" `
            -BodyHtml $growHtml
    }

} catch {
    Write-Log "FAILED: $($_.Exception.Message)" 'ERROR'
    throw
}
