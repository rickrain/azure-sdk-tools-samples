<#
.SYNOPSIS
    Deploy a number of VMs based on the same given image, on an availablility set, load 
    balanced on the provided endpoint. Subsequent calls targeting the same service name 
    adds new instances.
.DESCRIPTION
    The VMs based on the provided image on the Azure image library are deployed on the same 
    availability set, and load balanced on the provided endpoint. If there is an 
    existing service with the given name with VMs deployed having the same base host name, 
    it simply adds new VMs load balanced on the same endpoint.
.EXAMPLE
    .\New-AzureRedundantVm.ps1 -NewService -ServiceName "myservicename" -ComputerNameBase "myhost" `
        -InstanceSize Small -Location "West US" -AffinityGroupName "myag" -EndpointName "http" `
        -EndpointProtocol tcp -EndpointPublicPort 80 -EndpointLocalPort 80 -InstanceCount 3
#>
param
( 
    # Switch to indicate adding VMs to an existing service, already load balanced.
    [Parameter(ParameterSetName = "Existing deployment")]
    [Switch]
    $ExistingService,
    
    # Switch to indicate to create a new deployment from scratch
    [Parameter(ParameterSetName = "New deployment")]
    [Switch]
    $NewService,
    
    # Cloud service name to deploy the VMs to
    [Parameter(Mandatory = $true)]
    [String]
    $ServiceName,
    
    # Base of the computer name the VMs are going to assume. 
    # For example, myhost, where the result will be myhost1, myhost2
    [Parameter(Mandatory = $true)]
    [String]
    $ComputerNameBase,
    
    # Size of the VMs that will be deployed
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $InstanceSize,
    
    # Location where the VMs will be deployed to
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $Location,
    
    # Affinity group the VMs will be placed in
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $AffinityGroupName,
    
    # Name of the load balanced endpoint on the VMs
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $EndpointName,
    
    # The protocol for the endpoint
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [ValidateSet("tcp", "udp")]
    [String]
    $EndpointProtocol,
    
    # Endpoint's public port number
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [Int]
    $EndpointPublicPort,
    
    # Endpoint's private port number
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [Int]
    $EndpointLocalPort,
    
    # Number of VM instances
    [Parameter(Mandatory = $false)]
    [Int]
    $InstanceCount = 6)

# The script has been tested on Powershell 3.0
Set-StrictMode -Version 3

# Following modifies the Write-Verbose behavior to turn the messages on globally for this session
$VerbosePreference = "Continue"

# Check if Windows Azure Powershell is avaiable
if ((Get-Module -ListAvailable Azure) -eq $null)
{
    throw "Windows Azure Powershell not found! Please install from http://www.windowsazure.com/en-us/downloads/#cmd-line-tools"
}

<#
.SYNOPSIS
    Adds a new affinity group if it does not exist.
.DESCRIPTION
   Looks up the current subscription's (as set by Set-AzureSubscription cmdlet) affinity groups and creates a new
   affinity group if it does not exist.
.EXAMPLE
   New-AzureAffinityGroupIfNotExists -AffinityGroupNme newAffinityGroup -Locstion "West US"
.INPUTS
   None
.OUTPUTS
   None
#>
function New-AzureAffinityGroupIfNotExists
{
    param
    (
        # Name of the affinity group
        [Parameter(Mandatory = $true)]
        [String]
        $AffinityGroupName,
        
        # Location where the affinity group will be pointing to
        [Parameter(Mandatory = $true)]
        [String]
        $Location)
    
    $affinityGroup = Get-AzureAffinityGroup -Name $AffinityGroupName -ErrorAction SilentlyContinue
    if ($affinityGroup -eq $null)
    {
        New-AzureAffinityGroup -Name $AffinityGroupName -Location $Location -Label $AffinityGroupName `
        -ErrorVariable lastError -ErrorAction SilentlyContinue | Out-Null
        if (!($?))
        {
            throw "Cannot create the affinity group $AffinityGroupName on $Location"
        }
        Write-Verbose "Created affinity group $AffinityGroupName"
    }
    else
    {
        if ($affinityGroup.Location -ne $Location)
        {
            Write-Warning "Affinity group with name $AffinityGroupName already exists but in location `
            $affinityGroup.Location, not in $Location"
        }
    }
}

# A SQL Server Image to instantiate the VM's from.
# For example, to find the latest SQL image...
# Get-AzureVMImage | Where-Object { $_.Label -ilike "SQL*" } | 
#     Sort-Object PublishedDate -Descending | Select-Object -Property ImageName -First 1
$imageName = "fb83b3509582419d99629ce476bcb5c8__SQL-Server-2012SP1-CU5-11.0.3373.0-Enterprise-ENU-Win2012"

if ($NewService.IsPresent)
{
    # Check the related affinity group
    $affinityGroupName = $AffinityGroupName
    New-AzureAffinityGroupIfNotExists -AffinityGroupName $affinityGroupName -Location $Location
}

$existingVMs = Get-AzureVM -ServiceName $ServiceName | Where-Object {$_.Name -Like "$ComputerNameBase*"} 
$vmNumberStart = 1
if ($existingVMs -ne $null)
{
    if (!($ExistingService.IsPresent) -and $NewService.IsPresent)
    {
        throw "Cannot add new instances to an existing set of instances when the ""new deployment"" parameter set `
        is active"
    }
    
    # Find the largest instance number   
    $highestInstanceNumber = ($existingVMs | 
        ForEach-Object {$_.Name.Substring($ComputerNameBase.Length, ($_.Name.Length - $ComputerNameBase.Length))} | 
            Measure-Object -Maximum).Maximum

    $vmNumberStart = $highestInstanceNumber + 1
    $firstVm = $existingVMs[0]
    
    $loadBalancedEndpoint = Get-AzureEndpoint -VM $firstVm | Where-Object {$_.LBSetName -ne $null}
    if ($loadBalancedEndpoint -eq $null)
    {
        throw "No load balanced endpoints on the VMs"
    }
    
    $availabilitySetName = $firstVm.AvailabilitySetName
    $imageName = (Get-AzureOSDisk -VM $firstVm).SourceImageName
    $InstanceSize = $firstVm.InstanceSize
    $EndpointName = $loadBalancedEndpoint.Name
    $EndpointProtocol = $loadBalancedEndpoint.Protocol
    $EndpointLocalPort = $loadBalancedEndpoint.LocalPort
    $EndpointPublicPort = $loadBalancedEndpoint.Port
    $lbSetName = $loadBalancedEndpoint.LBSetName
    $DirectServerReturn = $loadBalancedEndpoint.EnableDirectServerReturn
} 

$vms = @()

$lbSetName = "LB" + $EndpointName
$availabilitySetName = $EndpointName + "availability"

$credential = Get-Credential

$service = Get-AzureService -ServiceName $ServiceName -ErrorAction SilentlyContinue

if ($service -eq $null)
{
    New-AzureService -ServiceName $ServiceName -Location $Location
}

for ($index = $vmNumberStart; $index -lt $InstanceCount + $vmNumberStart; $index++)
{
    $ComputerName = $ComputerNameBase + $index
    $directLocalPort = 30000 + $index
    $directInstanceEndpointName = "directInstance" + $index
    $vm = New-AzureVMConfig -Name $ComputerName -InstanceSize $InstanceSize -ImageName $imageName `
            -AvailabilitySetName $availabilitySetName | 
            Add-AzureEndpoint -Name $EndpointName -Protocol $EndpointProtocol -LocalPort $EndpointLocalPort `
            -PublicPort $EndpointPublicPort -LBSetName $lbSetName -ProbeProtocol $EndpointProtocol `
            -ProbePort $EndpointPublicPort | 
            Add-AzureEndpoint -Name "directInstancePort" -Protocol $EndpointProtocol -LocalPort $EndpointLocalPort `
            -PublicPort $directLocalPort | 
            Add-AzureProvisioningConfig -Windows -AdminUsername $credential.GetNetworkCredential().UserName `
            -Password $credential.GetNetworkCredential().Password 
    
    New-AzureVM -ServiceName $ServiceName -VMs $vm -WaitForBoot | Out-Null
    if ($?)
    {
        Write-Verbose "Created the VM."
    } 
}
