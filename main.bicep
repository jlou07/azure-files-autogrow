// =============================================================================
// Auto-Grow Azure Files (Provisioned v2) - Full Stack Deployment
// =============================================================================
// Deploys:
//   - Automation Account with System-Assigned Managed Identity
//   - Az.Accounts + Az.Storage PowerShell 7.2 modules
//   - The Grow-FslogixShare runbook (content fetched from a URI or uploaded post-deploy)
//   - A recurring schedule
//   - Azure Communication Services + Email Communication Service + Managed Domain
//     for sending notification emails (no Graph / no tenant admin consent required)
// =============================================================================

@description('Location for the Automation Account.')
param location string = resourceGroup().location

@description('Name of the Automation Account to create.')
param automationAccountName string = 'aa-autogrow-${uniqueString(resourceGroup().id)}'

@description('Public URI where the Grow-FslogixShare.ps1 script is hosted (e.g. GitHub raw URL). Leave empty when using the Cloud Shell flow that uploads content post-deploy.')
param runbookScriptUri string = ''

@description('Subscription ID containing the target storage account.')
param targetSubscriptionId string = subscription().subscriptionId

@description('Resource group of the target storage account.')
param targetResourceGroupName string

@description('Name of the target storage account (FileStorage with PremiumV2/StandardV2 SKU).')
param targetStorageAccountName string

@description('Name of the Provisioned v2 file share to monitor.')
param targetFileShareName string

@description('Trigger growth when usage reaches this percent of provisioned quota.')
@minValue(50)
@maxValue(95)
param thresholdPercent int = 80

@description('Quota multiplier applied when growing (1.25 = +25%).')
param growthFactor string = '1.25'

@description('Hard cap on quota (GiB) to prevent runaway growth.')
@minValue(32)
@maxValue(262144)
param maxQuotaGiB int = 4096

@description('How often the runbook runs.')
@allowed([
  'PT15M'
  'PT30M'
  'PT1H'
])
param scheduleInterval string = 'PT30M'

@description('Schedule start time. Default = 10 minutes after deployment. utcNow() is only valid as a parameter default in Bicep.')
param scheduleStartTime string = dateTimeAdd(utcNow(), 'PT10M')

@description('Recipient email address for notifications. Can be ANY address (internal or external — gmail, etc.). Leave empty to disable notifications.')
param notificationEmail string = ''

@description('Data location for the Azure Communication Services resources. Must comply with your data residency requirements.')
@allowed([
  'Europe'
  'United States'
  'Asia Pacific'
  'Australia'
  'United Kingdom'
  'France'
  'Germany'
  'Switzerland'
  'UAE'
  'Korea'
  'India'
  'Canada'
  'Japan'
  'Brazil'
])
param acsDataLocation string = 'Europe'

@description('Name of the Communication Services resource.')
param communicationServiceName string = 'acs-autogrow-${uniqueString(resourceGroup().id)}'

@description('Name of the Email Communication Service resource.')
param emailServiceName string = 'email-autogrow-${uniqueString(resourceGroup().id)}'

// -----------------------------------------------------------------------------
// Automation Account with System-Assigned Managed Identity
// -----------------------------------------------------------------------------
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
  }
}

// -----------------------------------------------------------------------------
// PowerShell 7.2 Modules (Az.Accounts must come first — Az.Storage depends on it)
// -----------------------------------------------------------------------------
// IMPORTANT: pin module versions. Latest from Gallery (Az.Accounts 5.x) requires
// .NET assemblies not present in the PS 7.2 Automation runtime, causing
// "Could not load file or assembly 'Microsoft.Identity.Client.Extensions.Msal'".
// Az.Accounts 2.19.0 + Az.Storage 6.1.0 is a known-good combo for PS 7.2.
resource azAccountsModule 'Microsoft.Automation/automationAccounts/powerShell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Accounts'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/2.19.0'
      version: '2.19.0'
    }
  }
}

resource azStorageModule 'Microsoft.Automation/automationAccounts/powerShell72Modules@2023-11-01' = {
  parent: automationAccount
  name: 'Az.Storage'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Storage/6.1.0'
      version: '6.1.0'
    }
  }
  dependsOn: [
    azAccountsModule
  ]
}

// -----------------------------------------------------------------------------
// Runbook (content fetched from external URI at publish time)
// -----------------------------------------------------------------------------
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Grow-FslogixShare'
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logProgress: false
    logVerbose: false
    description: 'Auto-grows Azure Files v2 share quota based on used capacity.'
    publishContentLink: empty(runbookScriptUri) ? null : {
      uri: runbookScriptUri
      version: '1.0.0.0'
    }
  }
  dependsOn: [
    azStorageModule
  ]
}

// -----------------------------------------------------------------------------
// Schedule
// -----------------------------------------------------------------------------
resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'AutoGrowSchedule'
  properties: {
    description: 'Recurring trigger for the Grow-FslogixShare runbook.'
    startTime: scheduleStartTime
    frequency: scheduleInterval == 'PT1H' ? 'Hour' : 'Minute'
    interval: scheduleInterval == 'PT15M' ? 15 : scheduleInterval == 'PT30M' ? 30 : 1
  }
}

// -----------------------------------------------------------------------------
// Azure Communication Services — for sending notification emails
// -----------------------------------------------------------------------------
// We deploy:
//   1. An Email Communication Service (the "email back-end")
//   2. An Azure Managed Domain inside it (provides a free DoNotReply@<guid>.azurecomm.net)
//   3. A Communication Services resource that links the managed domain
// Sending uses Entra ID auth (managed identity) with the Contributor role on the
// ACS resource — no connection strings, no secrets, no tenant admin consent.
// -----------------------------------------------------------------------------
resource emailService 'Microsoft.Communication/emailServices@2023-04-01' = if (!empty(notificationEmail)) {
  name: emailServiceName
  location: 'global'
  properties: {
    dataLocation: acsDataLocation
  }
}

resource emailDomain 'Microsoft.Communication/emailServices/domains@2023-04-01' = if (!empty(notificationEmail)) {
  parent: emailService
  name: 'AzureManagedDomain'
  location: 'global'
  properties: {
    domainManagement: 'AzureManaged'
    userEngagementTracking: 'Disabled'
  }
}

resource communicationService 'Microsoft.Communication/communicationServices@2023-04-01' = if (!empty(notificationEmail)) {
  name: communicationServiceName
  location: 'global'
  properties: {
    dataLocation: acsDataLocation
    linkedDomains: [
      emailDomain.id
    ]
  }
}

// -----------------------------------------------------------------------------
// Grant the Automation Account's managed identity Contributor on the ACS
// resource so it can send email via Entra ID auth
// (action: Microsoft.Communication/CommunicationServices/Email/Send/action).
// Scope is just the ACS resource — far narrower than tenant-wide Mail.Send.
// -----------------------------------------------------------------------------
resource acsContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(notificationEmail)) {
  name: guid(communicationService.id, automationAccount.id, 'Contributor')
  scope: communicationService
  properties: {
    // Contributor — includes Microsoft.Communication/CommunicationServices/Email/Send/action
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// NOTE: Storage Account Contributor on the target storage account is handled by
// the deploy-cloudshell.sh script via `az role assignment create` after this
// Bicep deployment completes. This keeps the Bicep file at a single RG scope.
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// NOTE: The link between the schedule and the runbook (jobSchedule) is created
// by the deploy-cloudshell.sh script AFTER the runbook content is uploaded and
// published. Creating the jobSchedule here would fail with
// "The runbook does not have a published version" because the Bicep deployment
// only creates an empty runbook shell when runbookScriptUri is empty.
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
output automationAccountId string = automationAccount.id
output automationAccountName string = automationAccount.name
output managedIdentityPrincipalId string = automationAccount.identity.principalId
output runbookName string = runbook.name
output scheduleName string = schedule.name
output acsEndpoint string = empty(notificationEmail) ? '' : 'https://${communicationService.properties.hostName}'
output acsSenderAddress string = empty(notificationEmail) ? '' : 'DoNotReply@${emailDomain.properties.mailFromSenderDomain}'
