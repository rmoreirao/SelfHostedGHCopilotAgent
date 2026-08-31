using './main.bicep'

param location = 'westeurope'
param resourceGroupName = 'rg-copilot-aks-poc-weu'
param githubRepository = 'rmoreirao/SelfHostedGHCopilotAgent'
param kubernetesVersion = '1.35'
param runnerScaleSetName = 'copilot-aks-poc'
param maxRunners = 3
