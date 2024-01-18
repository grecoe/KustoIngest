<#
    Script generates a CSV for each subscription in the configuration file spelling out 
    each of the instances that are invalid and the associated resource groups. Use this 
    to generate PBI items. 
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
    static [string] $SUBTYPE_INSTANCE = "Instance"
    static [string] $SUBTYPE_CLUSTER = "Cluster"
    static [string] $SUBTYPE_PARTITION = "Partition"

    static [string] $INSTANCE_GROUP = "compute-rg"
    static [string] $CLUSTER_GROUP ="mc_compute-rg"
    static [string] $PARTITION_GROUP ="datapartition-rg-"
    static [string] $ONEBOX_GROUP = "cloud-onebox"

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
                ManagedBy    = $group.ManagedBy 
                Id           = $group.ResourceId 
                IsInstance   = $false
                InstanceName = $null
                SubType      = $null
                Clusters     = New-Object System.Collections.ArrayList
                Partitions   = New-Object System.Collections.ArrayList
                }    
            
            # Is it an istance?
            $lowName = $found.Name.ToLower()
            if( $lowName.StartsWith([Utils]::INSTANCE_GROUP) -or ([string]::IsNullOrEmpty($found.ManagedBy) -and $lowName.Contains([Utils]::ONEBOX_GROUP)))
            {
                $found.IsInstance = $true
                $found.SubType = [Utils]::SUBTYPE_INSTANCE
            }
            elseif($lowName.StartsWith([Utils]::CLUSTER_GROUP) )
            {
                $found.SubType = [Utils]::SUBTYPE_CLUSTER
            }
            elseif ($lowName.StartsWith([Utils]::PARTITION_GROUP)) 
            {
                $found.SubType = [Utils]::SUBTYPE_PARTITION
            }

            if($found.SubType -ne $null)
            {
                $name_parts = $lowName.Split("-")
                if( $lowName.Contains([Utils]::ONEBOX_GROUP))
                {
                    $found.InstanceName = $name_parts[0]
                }
                else 
                {
                    $found.InstanceName = $name_parts[2]
                }
            }

            $resource_groups.Add($found) | Out-Null
        }
        return $resource_groups
    }

    static [System.Collections.ArrayList] LogicallyConnectGroups([System.Collections.ArrayList] $groups)
    {
        $logical_groups = New-Object System.Collections.ArrayList

        $managed_groups = $groups | ?{[string]::IsNullOrEmpty($_.ManagedBy) -eq $false} 
        $partitions = $groups | ?{$_.SubType -eq [Utils]::SUBTYPE_PARTITION} 

        # connect managed
        foreach($managed in $managed_groups)
        {
            $mgd_name = $managed.ManagedBy.Split("/")
            $parents = $groups | ?{$_.Name -eq $mgd_name[4] }

            foreach($p in $parents)
            {
                $p.Clusters.Add($managed) | Out-Null
            }
        }

        # Connect partitions
        foreach($partition in $partitions)
        {
            $parents = $groups | ?{$_.InstanceName -eq $partition.InstanceName -and $_.IsInstance -eq $true }
            foreach($p in $parents)
            {
                $p.Partitions.Add($partition) | Out-Null
            }
        }
        return $groups
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
$abandoned_instances = New-Object System.Collections.HashTable

foreach($subscripiton in $confObject.Subscriptions)
{
    # Make sure we are in the right subscription
    $azContext = [Utils]::VerifyContext($subscripiton)

    # Get all groups then use the well known logic to connect them together.
    $groups = [Utils]::GetResourceGroups()
    $connected = [Utils]::LogicallyConnectGroups($groups)
    Write-Host("Found", $groups.Count, "resource groups")

    <#
        With the information collected, create output objects to be used as input
        to the kusto ingestion python script.
    #>
    $connectedInstances = $connected | ?{$_.IsInstance -eq $true}

    foreach($inst in $connectedInstances)
    {
        $instance = New-Object PSObject -Property @{
            Name            = $inst.InstanceName
            Subscription    = $azContext.Name
            ResourceGroups  = $inst.Name
            Clusters        = New-Object System.Collections.ArrayList
            Partitions      = New-Object System.Collections.ArrayList 
            }   

        foreach($cluster in $inst.Clusters)
        {
            $instance.Clusters.Add($cluster.Name) | Out-Null
        }    
        foreach($partition in $inst.Partitions)
        {
            $instance.Partitions.Add($partition.Name) | Out-Null
        } 
    
        if( ($instance.Clusters.Count -eq 0) -or ($instance.Partitions.Count -eq 0))
        {
            if($abandoned_instances.ContainsKey($azContext.Name) -eq $false)
            {
                $abandoned = New-Object PSObject -Property @{
                    Subscription    = $azContext.Name
                    Instances      = New-Object System.Collections.ArrayList
                    }  
                $abandoned_instances.Add($azContext.Name, $abandoned) | Out-Null
            }

            $abandoned_instances[$azContext.Name].Instances.Add($instance) | Out-Null
        }
    }
}


foreach($subName in $abandoned_instances.Keys)
{
    $file = [String]::Format("{0}.csv", $subName)
    if (Test-Path $file) {
        Remove-Item $file
    } 
    New-Item $file | Out-Null

    Add-Content -Path $file -Value "Instance,InstanceGroup,ComputeGroup,DataPartition"

    Write-Host($file)
    foreach($instance in $abandoned_instances[$subName].Instances)
    {
        $compute = ""
        $partition = ""
        if($instance.Clusters.Count -gt 0 )
        {
            $compute = $instance.Clusters[0]
        }
        if($instance.Partitions.Count -gt 0 )
        {
            $partition = $instance.Partitions[0]
        }

        $inst_content = [string]::Format("{0},{1},{2},{3}", 
            $instance.Name,
            $instance.ResourceGroups,
            $compute,
            $partition)
        Add-Content -Path $file -Value $inst_content
    }
}