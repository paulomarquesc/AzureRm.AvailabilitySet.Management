<#
.SYNOPSIS
	AzureRm.AvailabilitySet.CoreHelper.psm1 - Contains helper functions.
.DESCRIPTION
	Contains helper functions.
#>
function GetParameterNameFromValue
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$VMName,
        [Parameter(Mandatory=$true)]
        $parameterSection
    )

    foreach ($prop in $parameterSection.psobject.Properties)
    {
        if ($prop.value.defaultValue -ieq $VMName.ToLower())
        {
            return $prop.Name
        }
    }
}

function Add-AzureRmAvSetVmToAvailabilitySet
{
    <#
    .SYNOPSIS
        Add-AzureRmAvSetVmToAvailabilitySet - This sample cmdlet adds/moves a VM(s) to an availability sets through exporting, deleting the original VM and importing it back.
    .DESCRIPTION
        Add-AzureRmAvSetVmToAvailabilitySet - This sample cmdlet adds/moves a VM(s) to an availability sets through exporting, deleting the original VM and importing it back.
    .PARAMETER ResourceGroup
        Name of the resource group where the VM resides
    .PARAMETER VMName
        List of VMs to be included in the same AV Set, worth it to notice that this VMs needs to be of the same VM Size.
        e.g. "vm1","vm2"
    .PARAMETER OsType
        Which OS type are those VMs, Windows or Linux, this is required when attached an existing OS Disk to a newly created VM.
        Setting up the wrong OS Name may leave the VM in an unsupported state and unpredictable issues may happen.
    .PARAMETER AvailabilitySet
        Name of the existing AvailabilitySet, must be in the same resource group where the VMs resides.
    .EXAMPLE
        Add-AzureRmAvSetVmToAvailabilitySet -ResourceGroupName rg-avset-test -VMName vm1 -OsType windows -AvailabilitySet avset
    .NOTES
        * Export-AzureRmResourceGroup will export the VM resources whitout any Extension and Diagnostics, so when it is imported back those items will need to be manually added back.
        * This script deletes the original VM configuration to import it back, a backup of the template is always made and can be used to reinstantiate the VM as they were before. 
        * It is strongly recommended to have a full backup of the VM and test it before allowing the script to delete the VM.
        * Execution of this script is at your own risk.
    #>
	[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
	param
	(
		[Parameter(Mandatory=$true)]
		[string]$ResourceGroupName,
    
		[Parameter(Mandatory=$true)]
		[string[]]$VMName,

		[Parameter(Mandatory=$true)]
		[validateSet("windows","linux",IgnoreCase=$true)]
		[string]$OsType,

		[Parameter(Mandatory=$true)]
		[string]$AvailabilitySet
	)
    
    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

	$ExecutionTimeStamp = Get-Date -Format 'yyyy-MM-dd_hhmmss'

    $originalTemplateFile = [System.IO.Path]::Combine($PSScriptRoot,[string]::Format("{0}-{1}.json","OriginalTemplate",$ExecutionTimeStamp))
    Write-Verbose "Original resource group ARM template file name: $originalTemplateFile" -Verbose

    $newTemplateFile = [System.IO.Path]::Combine($PSScriptRoot,[string]::Format("{0}-{1}.json","NewTemplate",$ExecutionTimeStamp))
	Write-Verbose "New resource group ARM template file name: $newTemplateFile" -Verbose

	try
	{
		# Getting the existing AvailabilitySet
		Write-Verbose "Getting the existing AvailabilitySet" -Verbose
		$avset = Get-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $AvailabilitySet -ErrorAction SilentlyContinue

		if ($avSet -eq $null)
		{
			throw "Availability Set $AvailabilitySet not found at Resource Group $ResourceGroupName."
		}

		# Exporting resource group
		Write-Verbose "Exporting resource group" -Verbose
		Export-AzureRmResourceGroup -ResourceGroupName $ResourceGroupName -Path $originalTemplateFile -IncludeParameterDefaultValue -force

		# Reading original template file
		$rgdef = Get-Content $originalTemplateFile | ConvertFrom-Json

		# Removing AdminPassword parameters that are not used when importing an existing Os Disk
		foreach ($prop in $rgdef.parameters.psobject.Properties)
		{
			if ($prop.name.contains("adminPassword") -or $prop.name.contains("primary") -or $prop.name.contains("extensions_Microsoft."))
			{
				$rgdef.parameters.psobject.Properties.Remove($prop.Name)
			}
		}

		# Filtering resources for only VMs that will be included 
		$resources = @()
		foreach ($vm in $VMName)
		{
            $vmNameParameterName = GetParameterNameFromValue -VMName $vm -parameterSection $rgdef.parameters
			$resources += $rgdef.resources | ? {$_.type -eq "Microsoft.Compute/virtualMachines" -and $_.name.Contains($vmNameParameterName)}
		}
		$rgdef.resources = $resources

		# Checking if all VMs are of the same size
		$vmSize = @()
		$vmSize += $rgdef.resources.properties.hardwareProfile | Select-Object -Unique

		if ($vmSize -eq 1)
		{
			throw "Not all VMs are the same size, Availability Sets only accepts VMs of the same size"
		}

		# Changing original VM resources to attach disks and add to the availability set
		foreach ($vmResource in $rgdef.resources)
		{
			# Checking Availability Set Alignment according to managed or unmanaged disks
			if ($vmResource.properties.storageProfile.osDisk.psobject.Properties["vhd"] -eq $null)
			{
				if ($avset.Sku -ne "Aligned")
				{
					throw "VM is using Managed disks and the Availability is not aligned with Managed Disks"
				}
			}
			else
			{
				if ($avset.Sku -ne "Classic")
				{
					throw "VM is using UnManaged Disks and Availability set should be Classic type."
				}
			}

			# Removing any dependencies since they already exists
			$vmResource.dependsOn = $null

			# Changing OS Disk to attach insted of using FromImage since this VM was already deployed
			$vmResource.properties.storageProfile.osDisk.createOption = "Attach"
        
			# Nullifying osProfile since this is used during a new deployment only
			if ($vmResource.properties.psobject.Properties["osProfile"] -ne $null)
			{
				$vmResource.properties.osProfile = $null
			}

			# Required by the Platform, adding the OsType parameter
			if ([string]::IsNullOrEmpty($vmResource.properties.storageProfile.osDisk.osType))
			{
				$vmResource.properties.storageProfile.osDisk | Add-Member -Type NoteProperty -Name "osType" -Value $osType.ToLower()
			}
        
			# Nullifying ImageReference since this is only for new VMs
			if ($vmResource.properties.storageProfile.psobject.Properties["imageReference"] -ne $null)
			{
				$vmResource.properties.storageProfile.imageReference = $null
			}

			# Changing creation option of data disks to Attach instead of new
			if ($vmResource.properties.storageProfile.dataDisks.Count -gt 0)
			{
				foreach ($datadisk in $vmResource.properties.storageProfile.dataDisks)
				{
					$datadisk.createOption = "Attach"
				}
			}

			# Removing Primary attribute of network Id
			foreach ($nic in $vmResource.properties.networkProfile.networkInterfaces)
			{
				if ($nic.properties -ne $null)
				{
					if ($nic.properties.psobject.Properties["primary"] -ne $null)
					{
						$nic.properties.psobject.properties.remove("primary")
					}
				}
			}

			# Adding Availability Set Id to VM
			foreach ($properties in $vmResource.Properties)
			{
				if ([string]::IsNullOrEmpty($vmResource.properties.availabilitySet))
				{
					$properties | Add-Member -Type NoteProperty -Name "availabilitySet" -Value @{"id"=$avset.id}
				}
				else
				{
					$properties.availabilitySet = @{"id"=$avset.id}
				}
			}
		}

		# Generating the new JSON Template to be executed to import the VMs back.
		Write-Verbose "Generating the new JSON Template to be executed to import the VMs back." -Verbose

        if ($rgdef.resources.count -gt 0)
        {

		    $rgdef | ConvertTo-Json -Depth 100 | % {$_.replace("\u0027","`'")} | Out-File $newTemplateFile

		    if ($PSCmdlet.ShouldProcess($ResourceGroupName,"Confirm that VMs can be excluded from resource group (VHDs are preserved)?"))
		    {

				Test-AzureRmResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
													-Mode Incremental `
													-TemplateFile $newTemplateFile `
													-Verbose

			    foreach ($vm in $VMName)
			    {
				    # Stopping VMs and removing their deployment
					Write-Verbose "Stopping VM $vm" -Verbose
					
					$vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $vm -Status

					if ($vm.statuses[1].Code -ne "PowerState/deallocated")
					{
						Stop-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $vm -Force -ErrorAction Continue
					}
				    
				    Write-Verbose "Deleting VM $vm from Resource Group $ResourceGroupName (VHDs are preserved and VMs will be imported in the next steps)" -Verbose
				    Remove-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $vm -Force -ErrorAction Continue
			    }

			    Write-Verbose "Deploying the new template." -Verbose
			    New-AzureRmResourceGroupDeployment -Name "SettingUpAvailabilitySets-$ExecutionTimeStamp" `
												       -ResourceGroupName $ResourceGroupName `
												       -Mode Incremental `
												       -TemplateFile $newTemplateFile `
												       -Force -Verbose  
		    }
        }
        else
        {
            throw "Resouces section of template is empty after transformations, aborting operation."
        }
	}
	catch
	{
		Write-Error "An error ocurred: $_"
    
	}
}

function Remove-AzureRmAvSetVmFromAvailabilitySet
{
    <#
    .SYNOPSIS
        Remove-AzureRmAvSetVmFromAvailabilitySet - This sample cmdlet removes a VM(s) from an availability set through exporting, deleting the original VM and importing it back.
    .DESCRIPTION
        Remove-AzureRmAvSetVmFromAvailabilitySet - This sample cmdlet removes a VM(s) from an availability set through exporting, deleting the original VM and importing it back.
    .PARAMETER ResourceGroup
        Name of the resource group where the VM resides
    .PARAMETER VMName
        VM to be included in the same AV Set, worth it to notice that this VMs needs to be of the same VM Size.
        e.g. "vm1"
    .PARAMETER OsType
        Which OS type are those VMs, Windows or Linux, this is required when attached an existing OS Disk to a newly created VM.
        Setting up the wrong OS Name may leave the VM in an unsupported state and unpredictable issues may happen.
    .EXAMPLE
            Remove-AzureRmAvSetVmFromAvailabilitySet -ResourceGroupName rg-avset-test -VMName vm1 -OsType windows
    .NOTES
        * Export-AzureRmResourceGroup will export the VM resources whitout any Extension and Diagnostics, so when it is imported back those items will need to be manually added back.
        * This script deletes the original VM configuration to import it back, a backup of the template is always made and can be used to reinstantiate the VM as they were before. 
        * It is strongly recommended to have a full backup of the VM and test it before allowing the script to delete the VM.
        * Execution of this script is at your own risk.
    #>
	[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
	param
	(
		[Parameter(Mandatory=$true)]
		[string]$ResourceGroupName,
    
		[Parameter(Mandatory=$true)]
		[string]$VMName,

		[Parameter(Mandatory=$true)]
		[validateSet("windows","linux",IgnoreCase=$true)]
		[string]$OsType
	)

    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

	$ExecutionTimeStamp = Get-Date -Format 'yyyy-MM-dd_hhmmss'

    $originalTemplateFile = [System.IO.Path]::Combine($PSScriptRoot,[string]::Format("{0}-{1}.json","OriginalTemplate",$ExecutionTimeStamp))
    Write-Verbose "Original resource group ARM template file name: $originalTemplateFile" -Verbose

    $newTemplateFile = [System.IO.Path]::Combine($PSScriptRoot,[string]::Format("{0}-{1}.json","NewTemplate",$ExecutionTimeStamp))
	Write-Verbose "New resource group ARM template file name: $newTemplateFile" -Verbose

	try
	{
		# Exporting resource group
		Write-Verbose "Exporting resource group" -Verbose
		Export-AzureRmResourceGroup -ResourceGroupName $resourceGroupName -Path $originalTemplateFile -IncludeParameterDefaultValue -force

		# Reading original template file
		$rgdef = Get-Content $originalTemplateFile | ConvertFrom-Json

		# Removing AdminPassword parameters that are not used when importing an existing Os Disk
		foreach ($prop in $rgdef.parameters.psobject.Properties)
		{
			if ($prop.name.contains("adminPassword") -or $prop.name.contains("primary") -or $prop.name.contains("extensions_Microsoft."))
			{
				$rgdef.parameters.psobject.Properties.Remove($prop.Name)
			}
		}

		# Filtering resources for only VM that will be included 
		$resources = @()
        
        $vmNameParameterName = GetParameterNameFromValue -VMName $VMName -parameterSection $rgdef.parameters

		$resources += $rgdef.resources | ? {$_.type -eq "Microsoft.Compute/virtualMachines" -and $_.name.Contains($vmNameParameterName)}

		# Checking if VM is attached to a loadbalancer and removes the NIC from it
		if ($resources.properties.networkProfile.networkInterfaces.Count -gt 1)
		{
			throw "This script supports VMs with only one nic."
		}

		$networkId = $resources.properties.networkProfile.networkInterfaces.id
		$regex = "`'(\w*)[`']"
		$templateNicRef = (([regex]$regex).Matches($networkId))[0].Value

		$nicResource = $rgdef.resources | ? {$_.type -eq "Microsoft.Network/networkInterfaces" -and $_.name.Contains($templateNicRef)}

		if (!([string]::IsNullOrEmpty($nicResource.properties.ipconfigurations.properties.psobject.Properties["loadBalancerBackendAddressPools"])) -or !([string]::IsNullOrEmpty($nicResource.properties.ipconfigurations.properties.psobject.Properties["loadBalancerInboundNatRules"])))
		{
			if (!([string]::IsNullOrEmpty($nicResource.properties.ipconfigurations.properties.psobject.Properties["loadBalancerBackendAddressPools"])))
			{
				Write-Warning "VM is attached to a load balancer, removing NIC from load balancer backend address pool, consider reviewing this VM later to make sure any manual procedure must be executed in order to restablish connectivity. E.g. creating a public ip address and associating with the NIC plus Network Security Groups." -Verbose
				$nicResource.properties.ipconfigurations.properties.psobject.Properties.Remove("loadBalancerBackendAddressPools")
            
			}

			if (!([string]::IsNullOrEmpty($nicResource.properties.ipconfigurations.properties.psobject.Properties["loadBalancerInboundNatRules"])))
			{
				Write-Warning "VM is attached to a load balancer, removing NIC from load balancer inbond net rules, consider reviewing this VM later to make sure any manual procedure must be executed in order to restablish connectivity. E.g. creating a public ip address and associating with the NIC plus Network Security Groups." -Verbose
				$nicResource.properties.ipconfigurations.properties.psobject.Properties.Remove("loadBalancerInboundNatRules")
			}

			$nicResource.dependsOn = $null
			$resources += $nicResource
			$resources
		}

		$rgdef.resources = $resources

		# Checking if any VM has returned from the initial filtering

		$vm = $rgdef.resources | ? {$_.type -eq "Microsoft.Compute/virtualMachines"}
		if ($vm -eq $null)
		{
			throw "VM $VMName does not exist, exiting processing"
		}

		# Getting Nic resource
		$nic = $rgdef.resources | ? {$_.type -eq "Microsoft.Network/networkInterfaces"}

		# Changing original VM resources to attach disks and to remove the availability set
		foreach ($vmResource in ($rgdef.resources | ? {$_.type -eq "Microsoft.Compute/virtualMachines"}))
		{
			# Removing any dependencies since they already exists adding nic 
			$vmResource.dependsOn = @()
        
			if($nic -ne $null)
			{
				 $vmResource.dependsOn += [string]::Format("[concat('Microsoft.Network/networkInterfaces/','{0}')]",$rgdef.parameters.psobject.Properties[$templateNicRef.replace("'","")].Value.defaultValue)
			}

			# Changing OS Disk to attach insted of using FromImage since this VM was already deployed
			$vmResource.properties.storageProfile.osDisk.createOption = "Attach"
        
			# Nullifying osProfile since this is used during a new deployment only
			if ($vmResource.properties.psobject.Properties["osProfile"] -ne $null)
			{
				$vmResource.properties.osProfile = $null
			}

			# Required by the Platform, adding the OsType parameter
			if ([string]::IsNullOrEmpty($vmResource.properties.storageProfile.osDisk.osType))
			{
				$vmResource.properties.storageProfile.osDisk | Add-Member -Type NoteProperty -Name "osType" -Value $osType.ToLower()
			}
        
			# Nullifying ImageReference since this is only for new VMs
			if ($vmResource.properties.storageProfile.psobject.Properties["imageReference"] -ne $null)
			{
				$vmResource.properties.storageProfile.imageReference = $null
			}

			# Changing creation option of data disks to Attach instead of new
			if ($vmResource.properties.storageProfile.dataDisks.Count -gt 0)
			{
				foreach ($datadisk in $vmResource.properties.storageProfile.dataDisks)
				{
					$datadisk.createOption = "Attach"
				}
			}

			# Removing Primary attribute of network Id
			foreach ($vmNicSetting in $vmResource.properties.networkProfile.networkInterfaces)
			{
				if ($vmNicSetting.properties -ne $null)
				{
					if ($vmNicSetting.properties.psobject.Properties["primary"] -ne $null)
					{
						$vmNicSetting.properties.psobject.properties.remove("primary")
					}
				}
			}

			# Removing Availability Set from VM
			foreach ($properties in $vmResource.Properties)
			{
				if (!([string]::IsNullOrEmpty($properties.availabilitySet)))
				{
					$properties.psobject.Properties.Remove("availabilitySet")
				}
			}
		}

		# Generating the new JSON Template to be executed to import the VMs back.
		Write-Verbose "Generating the new JSON Template to be executed to import the VMs back." -Verbose
        if ($rgdef.resources.count -gt 0)
        {
		    $rgdef | ConvertTo-Json -Depth 100 | % {$_.replace("\u0027","`'")} | Out-File $newTemplateFile

		    if ($PSCmdlet.ShouldProcess($ResourceGroupName,"Confirm that VMs can be excluded from resource group (VHDs are preserved)?"))
		    {

			    # Stopping VMs and removing their deployment
			    Write-Verbose "Stopping VM $VMName" -Verbose
			    Stop-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force -ErrorAction SilentlyContinue

			    Write-Verbose "Deleing VM $VMName from Resource Group $ResourceGroupName (VHDs are preserved and VMs will be imported in the next steps)" -Verbose

			    Remove-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force -ErrorAction SilentlyContinue

			    # deleting Nic if it is attached to a load balancer, nic will be recreated through the modified template
			    if ($nic -ne $null)
			    {
				    Remove-AzureRmNetworkInterface -ResourceGroupName $ResourceGroupName -Name $rgdef.parameters.psobject.Properties[$templateNicRef.replace("'","")].Value.defaultValue -Force
			    }

			    Write-Verbose "Deploying the new template with VM removed from avset" -Verbose
			    New-AzureRmResourceGroupDeployment -Name "RemovingAvailabilitySets-$ExecutionTimeStamp" `
												       -ResourceGroupName $resourceGroupName `
												       -Mode Incremental `
												       -TemplateFile $newTemplateFile `
												       -Force -Verbose  
		    }
        }
        else
        {
            throw "Resouces section of template is empty after transformations, aborting operation."
        }
	}
	catch
	{
		Write-Error "An error ocurred: $_"
	}
}


