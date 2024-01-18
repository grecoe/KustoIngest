<#
    Script to scan subscriptions looking for specific patterns in resource groups, by name,
    which indicate that they are related to a single instance. 

    Required parameter of a configuation file, in the form of settings.json, that identifies 
    the Azure subscriptions in which to scan. 

    Outputs results to a local file, identified in settings.json, for the follow on Kusto upload
    script. 

    NOTE:
    For this to function correctly you must FIRST set up you AzCLI and PWSH credentials using 
    the following 2 commands.

    POWERSHELL: [pwsh -Command] Connect-AzAccount
    * if run on cmdline you must add in the part in brackets.

    COMMAND LINE: az login
#>
Param(
    [Parameter(mandatory=$true)]    
    [string]$Configuration
)

<#
    Utility class to switch context and scan a subscription resource groups and
    logically group them based on a known pattern. 
#>
class Utils {
    static [string] $SUBTYPE_USER_INSTANCE = "User"
    static [string] $SUBTYPE_GLOBAL_INSTANCE = "Global"

    static [string] $USER_INSTANCE = "-dev-controlplane"
    static [string] $GLOBAL_INSTANCE = "dev-controlplane-"

    static [PSObject] VerifyContext([string]$subscription_id){
        $current_context = Get-AzContext
    
        $result = New-Object PSObject -Property @{
            Subscription   = $current_context.Subscription.Id
            Name           = $current_context.Subscription.Name
        }

        if( $current_context.Subscription.Id -ne $subscription_id ){
            $new_context = Set-AzContext -SubscriptionId $subscription_id
            $result.Name = $new_context.Subscription.Name
            $ignore = az account set -s $subscription_id
        }

        Write-Host("Context set to", $result.Name)
        return $result
    }

    static [System.Collections.ArrayList] GetResourceGroups()
    {
        $resource_groups = New-Object System.Collections.ArrayList
        $active_groups = Get-AzResourceGroup

        foreach($group in $active_groups)
        {
            $found = New-Object PSObject -Property @{
                Name         = $group.ResourceGroupName
                Location     = $group.Location
                Id           = $group.ResourceId 
                Subscription = $null
                IsInstance   = $false
                User         = $null
                SubType      = $null
                Version      = $null
                }    
            
            # Is it an istance?
            $lowName = $found.Name.ToLower()
            if( $lowName.StartsWith([Utils]::GLOBAL_INSTANCE) )
            {
                $found.IsInstance = $true
                $found.SubType = [Utils]::SUBTYPE_GLOBAL_INSTANCE
            }
            elseif($lowName.Contains([Utils]::USER_INSTANCE) )
            {
                $found.IsInstance = $true
                $found.SubType = [Utils]::SUBTYPE_USER_INSTANCE
                $name_parts = $lowName.Split("-")
                $found.User = $name_parts[0]
            }

            if($found.IsInstance -eq $true)
            {
                if($group.Tags -ne $null -and $group.Tags.ContainsKey("VERSION"))
                {
                    $found.Version = $group.Tags["VERSION"]
                }
            }

            $resource_groups.Add($found) | Out-Null
        }
        return $resource_groups
    }
}

<#
    Verify that the given configuration file actually exists on disk, then
    load up the configuration settings for further processing.
#>
if( (Test-Path -Path $Configuration) -eq $false)
{
    Write-Host("Required Configuration File -Configuration")
    Exit
}
$content = [IO.File]::ReadAllText($Configuration)
$confObject = ConvertFrom-Json -InputObject $content

<#
    Subscriptions in configuration is a list of subscription IDs. Iterate over the 
    list and collect the data from each subscription.
#>
$instance_data = New-Object System.Collections.ArrayList

foreach($subscripiton in $confObject.Subscriptions)
{
    # Make sure we are in the right subscription
    $azContext = [Utils]::VerifyContext($subscripiton)

    # Get all groups then use the well known logic to connect them together.
    $groups = [Utils]::GetResourceGroups()
    Write-Host("Found", $groups.Count, "resource groups")

    <#
        With the information collected, create output objects to be used as input
        to the kusto ingestion python script.
    #>
    $connectedInstances = $groups | ?{$_.IsInstance -eq $true}

    foreach($inst in $connectedInstances)
    {
        $inst.Subscription = $azContext.Name
        $instance_data.Add($inst) | Out-Null

        Write-Host($inst.Subscription, $inst.User, $inst.Name)
    }
}


<#
    Output the results, the old result SHOULD be gone if the follow on Python script ran, 
    however, ensure that it doesn't exist now before writing out again.
#>
Write-Host("Found", $instance_data.Count, "instances across", $confObject.Subscriptions.Count, "subscriptions")

if (Test-Path $confObject.InstanceFile) {
    Remove-Item $confObject.InstanceFile
} 

New-Item $confObject.InstanceFile | Out-Null
$ouput_content = ConvertTo-Json $instance_data -Depth 12
Write-Host($output_content)
Add-Content -Path $confObject.InstanceFile -Value $ouput_content