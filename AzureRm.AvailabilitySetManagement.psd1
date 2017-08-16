@{

# ID used to uniquely identify this module
GUID = 'e499f088-3666-4baf-b9f8-8f298550d7ee'

# Author of this module
Author = 'Microsoft Corporation'

# Company or vendor of this module
CompanyName = 'Microsoft Corporation'

# Copyright statement for this module
Copyright = '© Microsoft Corporation. All rights reserved.'

# Description of the functionality provided by this module
Description = 'Sample functions to add/move/remove Azure VMs to and from Availability sets in ARM mode'

# HelpInfo URI of this module
#HelpInfoUri = 'http://go.microsoft.com/fwlink/?LinkId=XXX'

# Version number of this module
ModuleVersion = '1.0.0.0'

# Minimum version of the Windows PowerShell engine required by this module
PowerShellVersion = '2.0'

# Minimum version of the common language runtime (CLR) required by this module
CLRVersion = '2.0'

# Script module or binary module file associated with this manifest
#ModuleToProcess = ''

# Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
NestedModules = @('AzureRm.AvailabilitySet.CoreHelper.psm1',
                  'Add-AzureRmVmAvSetToAvailabilitySet.psm1',
				  'Remove-AzureRmVmAvSetFromAvailabilitySet.psm1')

FunctionsToExport = @('*')

VariablesToExport = '*'

}