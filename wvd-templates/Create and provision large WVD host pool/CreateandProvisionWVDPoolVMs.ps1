#great tip from https://www.gngrninja.com/script-ninja/2016/2/12/powershell-quick-tip-simple-logging-with-timestamps
function Get-TimeStamp {
    return "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
}

#feel free to modify these ones for testing
[int]$desiredPoolVMCount=50  #how many VMs you want at the end
[int]$allocationBatchSize=10 #how many VMs to include in a batch. DO NOT EXCEED 399 OR IT WON'T DEPLOY VIA ARM TEMPLATE
[int]$maxSimulanteousDeployments = 3 #theoretically can be change, but don't change at this time
$resourceGroupName="WVDTestRG" #this is the name of the resource group that will be created/used for the VMs
$VMNamingPrefix="megaVM" #this is the prefix that will get put in the VM names. Should be cosmetic
[int]$sleepTimeMin=5 #how long to sleep between waking up to check on status of batches

#if this is set to TRUE, then the resource group has a GUID appended on the end
#this makes it easy to clean up because you can just delete the resource group
#and all VMs will be deleted
$isTest = $true

#change if you want to, but is purely cosmetic
[string]$batchNamingPrefix="WVDDeploymentBatch"

#don't change these unless you have your own WVD environment.
#they are specific to the current testing environment
$location="centralus"
$targetVNETName="fabrikam-central"
$targetSubnetName="desktops"
$virtualNetworkResourceGroupName = "fabrikamwvd-central"

[array]$deployments = @()

#enforce most current rules to help catch run-time failures
Set-StrictMode -Version Latest


# Get the context
$Context = Get-AzContext
if ($Context -eq $null)
{
	Write-Error "Please authenticate to Azure using Login-AzAccount cmdlet and then run this script"
	exit
}

#for testing
if ($isTest) {
    Write-Host "$(Get-TimeStamp) Running in TEST mode. Resource group name will have a GUID appended"
    $resourceGroupName += New-Guid
}

#create resource group if necessary
Get-AzResourceGroup -Name $resourceGroupname -ErrorVariable notPresent -ErrorAction SilentlyContinue
if ($notPresent)
{
    #resource group doesn't exist, so create
    New-AzResourceGroup `
        -Name $resourceGroupname `
        -Location $location
}

#create VNET and subnet if necessary
Get-AzVirtualNetwork -Name $targetVNETName -ResourceGroup $virtualNetworkResourceGroupName -ErrorVariable notPresent -ErrorAction SilentlyContinue
if ($notPresent)
{
    #VNET doesn't exist, so create
    $virtualNetwork = New-AzVirtualNetwork `
        -ResourceGroupName $resourceGroupName `
        -Location $location `
        -Name $targetVNETName `
        -AddressPrefix 10.0.0.0/16

    Add-AzVirtualNetworkSubnetConfig `
        -Name $targetSubnetName `
        -AddressPrefix 10.0.0.0/24 `
        -VirtualNetwork $virtualNetwork

    $virtualNetwork | Set-AzVirtualNetwork
}

#general logic flow is as follows:
#deploy up to maxSimulanteousDeployments each one having the allocation batch size
#sleep for a bit
#wake up and check if we have less than maxSimulanteousDeployments deployments running
#if so, then kick off a deployment of the allocation batch size or the rest of the VMs needed - whichever is smaller
#if not, do nothing

#start looping through creating VMs
[int]$deploymentIteration=0
do {

    #see how many VMs are in the resource group
    #loop through all the deployments which aren't already marked as completed
    #if they are done, update the Completed property
    #NOTE: for some reason Get-AzDeployment doesn't return any results (RBAC?) so am forced to use custom array
    #TODO: Switch this to checking on the job status

    #since we know how many VMs we want, let's figure out how many we need to deploy
    #query to see how many VMs already exist
    [int]$countExistingVMs=0
    [int]$countAdditionalVMs=0
    $existingVMs = @()
    $existingVMs = Get-AzVM -ResourceGroupName $resourceGroupName
    if (!$existingVMs) {
        #no VMs in the resource group yet
        $countExistingVMs = 0
    }
    else {
        #VMs already exist, so use the count
        $countExistingVMs = ($existingVMs | Measure-Object).Count
    }
    Write-Host "$(Get-TimeStamp) VMs already in resource group $($resourceGroupName): $($countExistingVMs)"

    Write-Host "$(Get-TimeStamp) Waking up to try and run another deployment"
    foreach ($deployment in $deployments) {
        if ($deployment.Completed -eq $false) {

            Write-Host "$(Get-TimeStamp) Checking status on $($deployment.Name)"
            $job = Get-Job -Name "$($deploymentName)"
            if (($job).State -eq "Completed")
            {
                Write-Host "$(Get-TimeStamp) Marking $($deployment.Name) as completed"
                $deployment.Completed = $true

                $dep= Get-AzResourceGroupDeployment -DeploymentName $deployment.Name -ResourceGroupName $resourceGroupName
                Write-Host "$(Get-TimeStamp) Marking $($deployment.Name) final state: $($dep.ProvisioningState)"
                $deployment.ProvisioningState = $dep.ProvisioningState
            }
            elseif (($job).State -eq "Failed") {
                Write-Host "$(Get-TimeStamp) Marking $($deployment.Name) as completed"
                $deployment.Completed = $true

                Write-Host "$(Get-TimeStamp) $($deployment.Name) final state: $($job.State)"
                $deployment.ProvisioningState = "Failed"
            }

#             #get all the operations running
#             $runningOperations = @(get-azresourcegroupdeploymentoperation `
#             -DeploymentName $deployment.Name -ResourceGroupName $resourceGroupName `
#             | Select-Object -ExpandProperty properties)
# #            | Where-Object {(($_.provisioningState -match "Running") -or ($_.provisioningState -match "Succeeded"))}
#             Write-Host "$(Get-TimeStamp) Running operations: $($runningOperations.Count)"

#             #if there are any, then see if any are VMs
#             #there HAVE to be VM operations at some point so if none exist then we haven't gotten far enough
#             if (($runningOperations | Measure-Object).Count -gt 0) {
                
#                 #filter down to just Create operations
#                 $createOperations = @($runningOperations | Where-Object {$_.provisioningOperation -match "Create"})
#                 Write-Host "$(Get-TimeStamp) Create operations: $($createOperations.Count)"

#                 if (($createOperations | Measure-Object).Count -gt 0)
#                 {
#                     #filter down to just VMs
#                     $vmOperations = @($createOperations | Where-Object {$_.targetResource -match "virtualMachines"})
#                     Write-Host "$(Get-TimeStamp) VM operations: $($vmOperations.Count)"

#                     if (($vmOperations | Measure-Object).Count -gt 0) {

#                         #find just the VM operations that are still running
#                         $runningVMOperations = @($vmOperations | Where-Object {$_.provisioningState -match "Running"})
#                         Write-Host "$(Get-TimeStamp) Running VM operations: $($runningVMOperations.Count)"

#                         #if none are still running, then we either fully completed or failed - either is acceptable here
#                         if (($runningVMOperations | Measure-Object).Count -eq 0)
#                         {
#                             Write-Host "$(Get-TimeStamp) Marking $($deployment.Name) as completed"
#                             $deployment.Completed=$true
#                         }
#                     }
#                 }
#             }
        }
    }

    #see if we need to kick off any deployments
    #if $deployments is null or current count less than $maxSimultaneousDeployments, then we need to allow deployments
    $needMoreDeployments = $false
    if (!$deployments) {
        #if no deployments at all, then allow more to kick off
        Write-Host "$(Get-TimeStamp) No deployments initiated - allowing a new one to run"
        $needMoreDeployments = $true
    }
    else {
        #if we have deployments already, then count all where not complete
        if ((($deployments | Where-Object {$_.Completed -eq $false}) | Measure-Object).Count -lt $maxSimulanteousDeployments) {

            #less than $maxSimultaneousDeployments, so allow more to kick off
            $needMoreDeployments = $true
            Write-Host "$(Get-TimeStamp) Less than $($maxSimulanteousDeployments) running - allow a new one to run"
        }
        else
        {
            Write-Host "$(Get-TimeStamp) More than $($maxSimulanteousDeployments) running - blocking new deployments"
            $needMoreDeployments = $false
        }
    }

    #kick of any necessary deployments to ensure we are always running $maxSimulanteousDeployments
    [int]$vmsToDeploy = 0
    if ($needMoreDeployments)
    {
        #now, figure out how many more VMs need created
        Write-Host "$(Get-TimeStamp) Desired total VMs: $($desiredPoolVMCount)"
        Write-Host "$(Get-TimeStamp) Existing VMs in pool: $($countExistingVMs)"

        $countAdditionalVMs = $desiredPoolVMCount - $countExistingVMs
        Write-Host "$(Get-TimeStamp) Additional VMs needed: $($countAdditionalVMs)"

        #exit strategy
        #if additonal VMs equal zero (or is negative=bad logic) then bail entirely
        if ($countAdditionalVMs -le 0)
        {
            Write-Host "$(Get-TimeStamp) All VMs needed deployed or deploying - exiting"
            break
        }

        #deploy either the total desired or the allocation pool count - whichever is smaller
        Switch ($allocationBatchSize -gt $countAdditionalVMs)
        {
            $true { 
                $vmsToDeploy = $countAdditionalVMs 
                Write-Host "$(Get-TimeStamp) $($allocationBatchSize)>$($countAdditionalVMs) - Additional VMs smallest. Only deploying what is needed"
            }
            $false {
                 $vmsToDeploy = $allocationBatchSize 
                 Write-Host "$(Get-TimeStamp) $($allocationBatchSize)<$($countAdditionalVMs) - Batch size smallest. Deploying full batch"
            }
        }

        #kick off an ARM deployment to deploy a batch of VMs
        [string]$uniqueIDforBatch = New-Guid
        $deploymentName="$($batchNamingPrefix)$($deploymentIteration)-$($uniqueIDforBatch)"
        (New-AzResourceGroupDeployment `
        -Name $deploymentName `
        -ResourceGroupName $resourceGroupName `
        -AsJob `
        -virtualNetworkResourceGroupName $virtualNetworkResourceGroupName `
        -rdshNumberOfInstances $vmsToDeploy `
        -location $location `
        -rdshNamePrefix "$($VMNamingPrefix)$($deploymentIteration)" `
        -_artifactsLocation "https://raw.githubusercontent.com/Azure/RDS-Templates/noAVSetSlowerHostAvailableCheck_20200218.1900_v1/wvd-templates/" `
        -TemplateUri "https://raw.githubusercontent.com/Azure/RDS-Templates/noAVSetSlowerHostAvailableCheck_20200218.1900_v1/wvd-templates/Create%20and%20provision%20WVD%20host%20pool/mainTemplate.json" `
        -TemplateParameterFile "C:\Users\evanba\source\repos\RDS-Templates\wvd-templates\Create and provision large WVD host pool\param_CreateandProvisionWVDPoolVMs.json_local").Name = $deploymentName

        #tracking object for deployment
        $deployment = New-Object -TypeName PSObject
        $deployment | Add-Member -Name 'Name' -MemberType Noteproperty -Value $deploymentName
        $deployment | Add-Member -Name 'Completed' -MemberType Noteproperty -Value $false
        $deployment | Add-Member -Name 'ProvisioningState' -MemberType NoteProperty -Value "Running"

        #make sure the deployment started OK. If not, then dump the error to the screen
        $job = Get-Job -Name "$($deploymentName)"
        if (($job).State -ne "Failed") {

            $deployment.ProvisioningState = $job.State

            #add the new deployment to the array for tracking purposes
            Write-Host "$(Get-TimeStamp) Successfully started deployment $($deploymentName)"

            $deployments += $deployment
            Write-Host "$(Get-TimeStamp) Added $($deploymentName) to tracking array"
    
            #increment the loop counter so the next iteration gets a different deployment name
            $deploymentIteration += 1
        }    
        else {
            $deployment.ProvisioningState = "Failed"
            Write-Host "$(Get-TimeStamp) $($deploymentName) failed validation"
            #job is in a failed state - report the reason
            $job = Get-Job -Name "$($deploymentName)"
            throw Receive-Job -Job $job -Keep
        }

    }

    #artificially reduce the sleep time for the first deployments
    #this way, we aren't waiting extra time while we are guaranteed
    #to not have enough deployments running
    if(($deploymentIteration-1) -lt $maxSimulanteousDeployments)
    {
        Write-Host "$(Get-TimeStamp) Haven't attempted enough deployments - reducing sleep time to 60 seconds"
        $sleepTimeMin = 1
    }

    #sleep for a bit to allow deployments to run
    Write-Host "$(Get-TimeStamp) Sleeping for $(60*$sleepTimeMin) seconds to let deployments run"
    Start-Sleep -s (60*$sleepTimeMin)

    Write-Host "$(Get-TimeStamp) deploymentIteration:$($deploymentIteration)"
    Write-Host "$(Get-TimeStamp) countAdditionalVMs:$($countAdditionalVMs)"
    Write-Host "$(Get-TimeStamp) allocationBatchSize:$($allocationBatchSize)"
} while (($deploymentIteration -ne 0) -and ($countAdditionalVMs -ge $allocationBatchSize))

Write-Host "$(Get-TimeStamp) Exiting"

#TODO: after everything is done, redeploy any deployed with failed VMs
#this will ensure any transient failures are addressed