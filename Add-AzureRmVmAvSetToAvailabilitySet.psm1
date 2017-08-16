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
	.NOTE
		* Export-AzureRmResourceGroup will export the VM resources whitout any Extension and Diagnostics, so when it is imported back those items will need to be manually added back.
		* This script deletes the original VM configuration to import it back, a backup of the template is always made and can be used to reinstantiate the VM as they were before. 
		* It is strongly recommended to have a full backup of the VM and test it before allowing the script to delete the VM.
		* Execution of this script is at your own risk.
	.DISCLAIMER
		This Sample Code is provided for the purpose of illustration only and is not intended to be used in a production environment.
		THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED,
		INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.  
		We grant You a nonexclusive, royalty-free right to use and modify the Sample Code and to reproduce and distribute the object
		code form of the Sample Code, provided that You agree: (i) to not use Our name, logo, or trademarks to market Your software
		product in which the Sample Code is embedded; (ii) to include a valid copyright notice on Your software product in which the
		Sample Code is embedded; and (iii) to indemnify, hold harmless, and defend Us and Our suppliers from and against any claims
		or lawsuits, including attorneys’ fees, that arise or result from the use or distribution of the Sample Code.
		Please note: None of the conditions outlined in the disclaimer above will supersede the terms and conditions contained
		within the Premier Customer Services Description.
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
		$avset = Get-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $AvailabilitySet

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

			    foreach ($vm in $VMName)
			    {
				    # Stopping VMs and removing their deployment
				    Write-Verbose "Stopping VM $vm" -Verbose
				    Stop-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $vm -Force -ErrorAction Continue

				    Write-Verbose "Deleing VM $vm from Resource Group $ResourceGroupName (VHDs are preserved and VMs will be imported in the next steps)" -Verbose
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

