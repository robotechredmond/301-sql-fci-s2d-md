
configuration ConfigS2D
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Parameter(Mandatory)]
        [String]$ClusterName,

        [Parameter(Mandatory)]
        [String]$vmNamePrefix,

        [Parameter(Mandatory)]
        [Int]$vmCount,

        [Parameter(Mandatory)]
        [Int]$vmDiskSize,

        [Parameter(Mandatory)]
        [String]$witnessStorageName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$witnessStorageKey,

        [String]$DomainNetbiosName=(Get-NetBIOSName -DomainName $DomainName),

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30

    )

    Import-DscResource -ModuleName xComputerManagement, xFailOverCluster, xActiveDirectory, xSOFS
 
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$DomainFQDNCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    [System.Collections.ArrayList]$Nodes=@()
    For ($count=0; $count -lt $vmCount; $count++) {
        $Nodes.Add($vmNamePrefix + $Count.ToString())
    }

    WaitForSqlSetup
    
    Node localhost
    {

        WindowsFeature FC
        {
            Name = "Failover-Clustering"
            Ensure = "Present"
        }

		WindowsFeature FailoverClusterTools 
        { 
            Ensure = "Present" 
            Name = "RSAT-Clustering-Mgmt"
			DependsOn = "[WindowsFeature]FC"
        } 

        WindowsFeature FCPS
        {
            Name = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature FS
        {
            Name = "FS-FileServer"
            Ensure = "Present"
        }

        xWaitForADDomain DscForestWait 
        { 
            DomainName = $DomainName 
            DomainUserCredential= $DomainCreds
            RetryCount = $RetryCount 
            RetryIntervalSec = $RetryIntervalSec 
	        DependsOn = "[WindowsFeature]ADPS"
        }
        
        xComputer DomainJoin
        {
            Name = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $DomainCreds
	        DependsOn = "[xWaitForADDomain]DscForestWait"
        }

        xCluster FailoverCluster
        {
            Name = $ClusterName
            DomainAdministratorCredential = $DomainCreds
            Nodes = $Nodes
	        DependsOn = "[xComputer]DomainJoin"
        }

        Script CloudWitness
        {
            SetScript = "Set-ClusterQuorum -CloudWitness -AccountName ${witnessStorageName} -AccessKey $($witnessStorageKey.GetNetworkCredential().Password)"
            TestScript = "(Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness'"
            GetScript = "@{Ensure = if ((Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness') {'Present'} else {'Absent'}}"
            DependsOn = "[xCluster]FailoverCluster"
        }

        Script IncreaseClusterTimeouts
        {
            SetScript = "(Get-Cluster).SameSubnetDelay = 2000; (Get-Cluster).SameSubnetThreshold = 15; (Get-Cluster).CrossSubnetDelay = 3000; (Get-Cluster).CrossSubnetThreshold = 15"
            TestScript = "(Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15"
            GetScript = "@{Ensure = if ((Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15) {'Present'} else {'Absent'}}"
            DependsOn = "[Script]CloudWitness"
        }

        Script EnableS2D
        {
            SetScript = "Enable-ClusterS2D -Confirm:0; New-Volume -StoragePoolFriendlyName S2D* -FriendlyName VDisk01 -FileSystem CSVFS_REFS -UseMaximumSize"
            TestScript = "(Get-ClusterSharedVolume).State -eq 'Online'"
            GetScript = "@{Ensure = if ((Get-ClusterSharedVolume).State -eq 'Online') {'Present'} Else {'Absent'}}"
            DependsOn = "[Script]IncreaseClusterTimeouts"
        }

        LocalConfigurationManager 
        {
            RebootNodeIfNeeded = $true
        }

    }

}

function Get-NetBIOSName
{ 
    [OutputType([string])]
    param(
        [string]$DomainName
    )

    if ($DomainName.Contains('.')) {
        $length=$DomainName.IndexOf('.')
        if ( $length -ge 16) {
            $length=15
        }
        return $DomainName.Substring(0,$length)
    }
    else {
        if ($DomainName.Length -gt 15) {
            return $DomainName.Substring(0,15)
        }
        else {
            return $DomainName
        }
    }
}

function WaitForSqlSetup
{
    # Wait for SQL Server Setup to finish before proceeding.
    while ($true)
    {
        try
        {
            Get-ScheduledTaskInfo "\ConfigureSqlImageTasks\RunConfigureImage" -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
        catch
        {
            break
        }
    }
}