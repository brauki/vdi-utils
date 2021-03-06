<#
.NOTES
     Created on:   4/10/2017
     Created by:   Andy Simmons
     Organization: St. Luke's Health System
     Filename:     Start-VDiskUpdateCleanupTasks.ps1

.SYNOPSIS
    Assists with getting and keeping users off of older vDisk versions, following
    an update to a non-persistent PVS image.

.DESCRIPTION
    Analyzes available machines to ensure they're all running the latest vDisk version,
    and reboots them as needed.

    Once all available machines are up to date, machines with sessions are analyzed.
    
    Whenever a session is found on a machine with an old vDisk, one of two actions will be
    taken, depending on the session state and the duration of that state. If a session was
    recently active, the user will be prompted to reboot.

    If the session has been inactive for a specified time period, the machine will be rebooted.

.LINK
    https://github.com/andysimmons/vdi-utils/blob/master/Start-VDiskUpdateCleanupTasks.ps1

.PARAMETER AdminAddress
    One or more delivery controllers.

.PARAMETER SearchScope
    Specifies which types of machines are in scope.

        AvailableMachines:
            Limit search to machines in an "Available" state.

        MachinesWithSessions:
            Limit search to machines associated with sessions.

        Both:
            Default option. Searches first for available machines, and if those
            are all up-to-date, looks for sessions on outdated vDisks.

.PARAMETER NagTitle
    Title of the nag message box.

.PARAMETER NagText
    Content of the nag message box.

.PARAMETER DeliveryGroup
    Pattern matching the delivery group name(s). Wildcards are supported, but
    regular expressions are not.

.PARAMETER RegistryKey
    Registry key (on the PVS target machine) containing a property that
    references the vDisk version in use.

.PARAMETER RegistryProperty
    Registry key property to inspect.

.PARAMETER AllVersionsPattern
    A pattern matching the naming convention for ANY version of the vDisk being updated.

    Regular expressions are supported.

.PARAMETER TargetVersionPattern
    A pattern describing the specific name of the target (updated) vDisk version.

    Regular expressions are supported.

.PARAMETER MaxRecordCount
    Maximum number of results per search, per site.

.PARAMETER MaxRestartActions
    Specifies the max number of reboots that can occur during script execution
    across all sites.

.PARAMETER TimeOut
    Timeout (sec) for querying vDisk information

.PARAMETER ThrottleLimit
    Max number of concurrent remote operations.

.PARAMETER MaxHoursIdle
    Maximum number of hours a session can be inactive before we forcefully shut it down.

.PARAMETER RunAsync
    Don't monitor reboot progress, just exit the script as soon as all tasks are queued on the DDCs.

.PARAMETER PowerActionTimeout
    Timeout (sec) for MONITORING the status of queued power actions.

.EXAMPLE
    Start-VDiskUpdateCleanupTasks.ps1 -AdminAddress ctxddc01,ctxddc02,sltctxddc01,sltctxddc02 -Verbose -WhatIf

    This would invoke the script against both of our production VDI sites with the default options, and
    describe in detail what would happen.

.EXAMPLE
    Start-VDiskUpdateCleanupTasks.ps1 -AdminAddress ctxddc01,sltctxddc01,ctxddc02,sltctxddc02 -Verbose -DeliveryGroup "XD*T07GCD" -Confirm:$false

    This would invoke the script against both of our VDI sites, targeting only the test delivery groups,
    and bypass confirmation prompts for any recommended actions.

.EXAMPLE
    Start-VDiskUpdateCleanupTasks.ps1 -AdminAddress ctxddc01,ctxddc02,sltctxddc01,sltctxddc02 -Verbose -DeliveryGroup "*PVS Shared Desktop" -MaxRestartActions 10

    This would invoke the script against both of our sites, targeting any Delivery Groups ending with the string "PVS Shared Desktop",
    and perform actions (with confirmation prompts) against a maximum of 10 machines/sessions total.
    
.EXAMPLE
    Start-VDiskUpdateCleanupTasks.ps1 -AdminAddress ctxddc01,ctxddc02,sltctxddc01,sltctxddc02 -Verbose -DeliveryGroup "*P07SLHS*" -SearchScope ‘AvailableMachines’ -Confirm:$false

    Ian's Example 1
.EXAMPLE
    Start-VDiskUpdateCleanupTasks.ps1 -AdminAddress ctxddc01,ctxddc02,sltctxddc01,sltctxddc02 -Verbose -DeliveryGroup "*P07CDR*" -SearchScope ‘AvailableMachines’ -Confirm:$false 

    Ian's Example 2
#>
#Requires -Version 5
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory)]
    [string[]]
    $AdminAddress,

    [string]
    [ValidateSet('AvailableMachines','MachinesWithSessions','Both')]
    $SearchScope = 'Both',

    [string]
    $NagTitle = 'RESTART REQUIRED',

    [string]
    $NagText = "Your system must be restarted to apply the latest Epic update.`n`n" + 
    "Please save your work, then click 'Start' -> 'Log Off', and then wait`n" + 
    'for the logoff operation to complete.',

    [string]
    $DeliveryGroup = "*",

    [string]
    $RegistryKey = 'HKLM:\System\CurrentControlSet\services\bnistack\PvsAgent',

    [string]
    $RegistryProperty = 'DiskName',

    [regex]
    $AllVersionsPattern = "XD[BT]?P07(GCD|SLHS)-\d{6}.vhd",

    [regex]
    $TargetVersionPattern = "XD[BT]?P07SLHS-yyMMdd.vhd",

    [int]
    $MaxRecordCount = ([int32]::MaxValue),

    [int]
    $MaxRestartActions = 1000,

    [int]
    $ThrottleLimit = 32,

    [int]
    $TimeOut = 120,

    [int]
    $MaxHoursIdle = 2,

    [switch]
    $RunAsync,

    [int]
    $PowerActionTimeout = 3600
)

[Collections.ArrayList]$asyncTasks = @()
[Collections.ArrayList]$whatIfTracker = @()
$scriptStart = Get-Date
$nagCount = 0
$nagFailCount = 0
$restartCount = 0
$restartFailCount = 0
$completedTaskCount = 0
$whatIfRestartCount = 0

enum UpdateStatus
{
    Ineligible
    Unknown
    RestartRequired
    UpdateCompleted
}

enum ProposedAction
{
    None
    Nag
    Restart
}

#region Functions
<#
.SYNOPSIS
    Pulls vDisk version information for a list of computers.

.DESCRIPTION
    Takes a list of computer names, checks which vDisk each one is currently running,
    and returns a hashtable with the results.

.PARAMETER TimeOut
    Timeout (sec) for querying vDisk information

.PARAMETER RegistryKey
    Registry key (on the PVS target machine) containing a property that
    references the vDisk version in use.

.PARAMETER RegistryProperty
    Registry key property to inspect.

.PARAMETER ComputerName
    The NetBIOS name, the IP address, or the fully qualified domain name of one or more computers.
#>
function Get-VDiskInfo
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]
        $ComputerName,
        
        [Parameter(Mandatory)]
        [int]
        $TimeOut,

        [Parameter(Mandatory)]
        [string]
        $RegistryKey,

        [Parameter(Mandatory)]
        [string]
        $RegistryProperty
    )

    # The PVS management snap-in is pretty awful at the time of this writing, so we'll use PS remoting
    # to reach out to each virtual desktop, have them check a registry entry, and return an object
    # containing the HostedMachineName and its current VHD.
    [scriptblock]$getDiskName = {
        [pscustomobject]@{
            DiskName = (Get-ItemProperty -Path $using:RegistryKey -ErrorAction SilentlyContinue).$using:RegistryProperty
        }
    }

    # Get as much info as we can within the timeout window.
    $vDiskJob = Invoke-Command -ComputerName $ComputerName -ScriptBlock $getDiskName -AsJob -JobName 'vDiskJob'
    Wait-Job -Job $vDiskJob -Timeout $TimeOut > $null
    $vDisks = Receive-Job -Job $vDiskJob -ErrorAction SilentlyContinue
    Get-Job -Name 'vDiskJob' | Remove-Job -Force -WhatIf:$false

    # Create a hashtable mapping the computer name to the vDisk name
    $activity = "Comparing $($sessions.Length) desktops against $($vDisks.Length) vDisk results."
    Write-Progress -Activity $activity -Status $controller
    $vDiskLookup = @{ }
    foreach ($vDisk in $vDisks)
    {
        $vDiskLookup[$vDisk.PSComputerName] = $vDisk.DiskName
    }
    Write-Progress -Activity $activity -Completed

    # Return the lookup table
    $vDiskLookup
}

<#
.SYNOPSIS
    Determines the update status of a given vDisk.

.PARAMETER AllVersionsPattern
    A pattern matching the naming convention for ANY version of the vDisk being updated.

.PARAMETER TargetVersionPattern
    A pattern describing the specific name of the target (updated) vDisk version.

.PARAMETER DiskName
    The name of the vDisk.
#>
function Get-UpdateStatus
{
    [CmdletBinding()]
    [OutputType([UpdateStatus])]
    param(
        [string]$DiskName,

        [regex]$AllVersionsPattern,

        [regex]$TargetVersionPattern
    )

    # If we know the vDisk name
    if ($DiskName)
    {
        # and it's a vDisk we're updating
        if ($DiskName -match $AllVersionsPattern)
        {
            # see if we're on the target version.
            if ($DiskName -match $TargetVersionPattern)
            {
                $updateStatus = [UpdateStatus]::UpdateCompleted
            }
            else
            {
                $updateStatus = [UpdateStatus]::RestartRequired
            }
        }
        # we aren't trying to update this vDisk.
        else
        {
            $updateStatus = [UpdateStatus]::Ineligible
        }
    }

    # no disk name provided
    else
    {
        $updateStatus = [UpdateStatus]::Unknown
    }

    # return result
    $updateStatus
}

<#
.SYNOPSIS
    Underlines a string.

.PARAMETER Header
    Header text.

.PARAMETER Double
    Displays header text with both under and overlines.
#>
function Out-Header
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Header,

        [switch]$Double
    )
    process
    {
        $line = $Header -replace '.', '-'

        if ($Double) 
        { 
            ''
            $line
            $Header
            $line 
        }
        else 
        { 
            ''
            $Header
            $line
        }
    }
}

<#
.SYNOPSIS
    Nag a VDI user with a popup.

.DESCRIPTION
    Generates a dialog box inside a VDI session.

.PARAMETER AdminAddress
    Controller address.

.PARAMETER HostedMachineName
    Hosted machine name associated with the session we're going to nag.

.PARAMETER Title
    Message dialog title text.

.PARAMETER Text
    Message dialog body text.

.PARAMETER MessageStyle
    Message dialog icon style.

.PARAMETER SessionUID
    Session UID.
#>
function Send-Nag
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory)]
        [string]$AdminAddress,

        [Parameter(Mandatory)]
        [string]$HostedMachineName,

        [Parameter(Mandatory)]
        [int]$SessionUID,

        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Title,

        [ValidateSet('Critical', 'Exclamation', 'Information', 'Question')]
        [string]$MessageStyle = 'Exclamation'
    )

    if ($PSCmdlet.ShouldProcess($HostedMachineName, "NAG USER"))
    {

        try
        {
            $session = Get-BrokerSession -AdminAddress $AdminAddress -Uid $SessionUID -ErrorAction Stop
        }
        catch
        {
            Write-Warning "Couldn't retrieve session ${AdminAddress}: ${SessionUID}"
            return
        }

        $nagParams = @{
            AdminAddress = $AdminAddress
            InputObject  = $session
            Title        = $Title
            Text         = $Text
            MessageStyle = $MessageStyle
            ErrorAction  = 'Stop'
        }

        try
        {
            Send-BrokerSessionMessage @nagParams
        }
        catch
        {
            Write-Warning $_.Exception.Message
            $script:nagFailCount++
        }

        $script:nagCount++
    }
}

<#
.SYNOPSIS
    Finds healthy Desktop Delivery Controllers (DDCs) from a list of candidates.

.DESCRIPTION
    Inspects each of the DDC names provided, verifies the services we'll be leveraging are
    responsive, and picks one healthy DDC per site.

.PARAMETER Candidates
    List of DDCs associated with one or more Citrix XenDesktop sites.
#>
function Get-HealthyDDC
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [Parameter(Mandatory)]
        [string[]]$Candidates
    )

    $siteLookup = @{ }

    foreach ($candidate in $Candidates)
    {
        $candidateParams = @{
            AdminAddress = $candidate
            ErrorAction  = 'Stop'
        }

        # Check service states
        try   { $brokerStatus = (Get-BrokerServiceStatus @candidateParams).ServiceStatus }
        catch { $brokerStatus = 'BROKER_OFFLINE' }

        try   { $hypStatus = (Get-HypServiceStatus @candidateParams).ServiceStatus }
        catch { $hypStatus = 'HYPERVISOR_OFFLINE' }

        # If it's healthy, check the site ID.
        if (($brokerStatus -eq 'OK') -and ($hypStatus -eq 'OK'))
        {
            try   { $brokerSite = Get-BrokerSite @candidateParams }
            catch { $brokerSite = $null }

            # We only want one healthy DDC per site
            if ($brokerSite)
            {
                $siteUid = $brokerSite.BrokerServiceGroupUid

                if ($siteUid -notin $siteLookup.Keys)
                {
                    Write-Verbose "Using DDC $candidate for sessions in site $($brokerSite.Name)."
                    $siteLookup[$siteUid] = $candidate
                }

                else
                {
                    Write-Verbose "Already using $($siteLookup[$siteUid]) for site $($brokerSite.Name). Skipping $candidate."
                }
            }
        }

        else
        {
            Write-Warning "DDC '$candidate' broker service status: $brokerStatus, hypervisor service status: $hypStatus. Skipping."
        }
    }

    # Return only the names of the healthy DDCs from our site lookup hashtable
    $siteLookup.Values
}

<#
.SYNOPSIS
    Checks the current status of previously queued HostingPowerActions, and
    returns the task if it's still pending.

.PARAMETER Task
    String following the format "<task UID>@<admin address>".

.EXAMPLE
    Get-PendingPowerAction -Task '123456@ctxddc01'
#>
function Get-PendingPowerAction
{
    [OutputType([string])]
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline, Mandatory)]
        [string]
        $Task
    )

    process
    {
        if ($Task -notmatch '[0-9]+@.+')
        {
            Write-Error "Discarding task '${Task}' because it looks funny." -Category ParserError
        }
        else 
        {
            $taskTokens   = $Task.ToUpper() -split '@'
            $taskUid      = $taskTokens[0]
            $adminAddress = $taskTokens[1]

            try
            {
                $taskInfo = Get-BrokerHostingPowerAction -AdminAddress $adminAddress -Uid $taskUid -ErrorAction 'Stop'
            }
            catch
            {
                Write-Warning $_.Exception.Message
                $taskInfo = $null
            }
            
            # Task is in its final state. Don't return it, just summarize.
            if ($taskInfo.ActionCompletionTime)
            {
                $action     = $taskInfo.Action
                $machine    = $taskInfo.HostedMachineName.ToString().ToUpper()
                $result     = $taskInfo.State.ToString().ToLower()
                $resultTime = $taskInfo.ActionCompletionTime

                if ($result -ne 'completed')
                {
                    $script:restartFailCount++
                }

                Write-Verbose "${machine} ${action} result: ${result} ($($adminAddress.ToUpper()): ${resultTime})"
            }

            # Still pending. Return it.
            else { $Task }
        } 
    }
}
#endregion Functions


#region Initialization
Write-Verbose "$(Get-Date): Started as '$($MyInvocation.Line)'"

# Obnoxious workaround. We'll summarize all interesting parameters (anything assigned - 
# both default and custom) inside a hashtable, and shoot that to verbose output.
$invocationParams = $PSBoundParameters
$supportedParams = (Get-Command -Name $MyInvocation.MyCommand.Source).Parameters

foreach ($key in $supportedParams.keys)
{
    $var = Get-Variable -Name $key -ErrorAction SilentlyContinue;
    if ($var)
    {
        $invocationParams[$var.name] = $var.value
    }
}
Write-Verbose "Parameter assignments...`n$($invocationParams | Format-Table -HideTableHeaders | Out-String)"

Write-Verbose 'Loading required Citrix snap-ins...'
[Collections.ArrayList]$missingSnapinList = @()
$requiredSnapins = @(
    'Citrix.Host.Admin.V2',
    'Citrix.Broker.Admin.V2'
)

foreach ($requiredSnapin in $requiredSnapins)
{
    Write-Verbose "Loading snap-in: $requiredSnapin"
    try   { Add-PSSnapin -Name $requiredSnapin -ErrorAction Stop }
    catch { $missingSnapinList.Add($requiredSnapin) > $null }
}

if ($missingSnapinList)
{
    Write-Error -Category NotImplemented -Message "Missing $($missingSnapinList -join ', ')"
    exit 1
}

Write-Verbose "Assessing DDCs: $($AdminAddress -join ', ')"
$controllers = @(Get-HealthyDDC -Candidates $AdminAddress)
if (!$controllers.Length)
{
    Write-Error -Category ResourceUnavailable -Message 'No healthy DDCs found.'
    exit 1
}
#endregion Initialization


#region Analysis

# Loop through the eligible controllers (one per site), analyze the AVAILABLE MACHINES on each to see
# what automated action should be taken, and store that report in a collection.
if ($SearchScope -eq 'MachinesWithSessions')
{
    # We're just targeting sessions this run, skip the available machine analysis.
    $availableMachineReport = @()
}

else
{
    [array]$availableMachineReport = foreach ($controller in $controllers)
    {
        $analysisStart = Get-Date 

        Write-Verbose "Analyzing available machines' vDisks on $($controller.ToUpper()) (this may take a minute)..."
        Write-Progress -Activity 'Pulling available machine list' -Status $controller

        $availableParams = @{
            AdminAddress     = $controller
            DesktopGroupName = $DeliveryGroup
            DesktopKind      = 'Shared'
            SummaryState     = 'Available'
            MaxRecordCount   = $MaxRecordCount
        }

        $availableMachines = Get-BrokerMachine @availableParams

        Write-Progress -Activity 'Pulling available machine list' -Completed

        if ($availableMachines)
        {
            Write-Progress -Activity "Querying $($availableMachines.Length) desktops for vDisk information (${TimeOut} sec timeout)." -Status $controller
            
            $lookupParams = @{
                ComputerName     = $availableMachines.HostedMachineName
                Timeout          = $Timeout
                RegistryKey      = $RegistryKey
                RegistryProperty = $RegistryProperty

            }
            $vDiskLookup = Get-VDiskInfo @lookupParams

            # Now we can loop through the sessions and handle them accordingly
            foreach ($availableMachine in $availableMachines)
            {
                try   { $vDisk = $vDiskLookup[$availableMachine.HostedMachineName] }
                catch { $vDisk = $null }

                $statusParams = @{
                    TargetVersionPattern = $TargetVersionPattern
                    AllVersionsPattern   = $AllVersionsPattern
                    DiskName             = $vDisk
                }

                $updateStatus = Get-UpdateStatus @statusParams

                # Propose an action based on update status
                switch ($updateStatus)
                {
                    'RestartRequired'
                    {
                        # Machine isn't in use, we should restart it.
                        $proposedAction = [ProposedAction]::Restart
                    }

                    default
                    {
                        # No action needed (or not enough info to propose an action)
                        $proposedAction = [ProposedAction]::None
                    }
                }

                # Summarize this machine
                [pscustomobject]@{
                    HostedMachineName = $availableMachine.HostedMachineName
                    DiskName          = $vDisk
                    UpdateStatus      = $updateStatus
                    ProposedAction    = $proposedAction
                    SummaryState      = $availableMachine.SummaryState
                    Uid               = $availableMachine.Uid
                    AdminAddress      = $controller.ToUpper()
                }
            }
        }

        else
        {
            Write-Verbose "No available machines found on $($controller.ToUpper())."
        }

        $elapsed = [int]((Get-Date) - $analysisStart).TotalSeconds
        Write-Verbose "Completed $($controller.ToUpper()) machine analysis in ${elapsed} seconds."
    }
    if ($availableMachineReport)
    {
        'Available Machine Summary' | Out-Header -Double
        $availableMachineReport | Format-Table -AutoSize
    }
}

if ($SearchScope -eq 'AvailableMachines')
{
    # Sessions are out of scope for this pass
    $sessionReport = @()
}
else
{
    # Loop through the eligible controllers (one per site), analyze the MACHINES WITH SESSIONS to see what
    # automated action should be taken, and store that report in a collection.
    [array]$sessionReport = foreach ($controller in $controllers)
    {
        $analysisStart = Get-Date

        $oldAvailableMachines = @(
            $availableMachineReport | 
                Where-Object { ($_.AdminAddress -eq $controller) -and ($_.ProposedAction -eq 'Restart') }
        )

        if ($oldAvailableMachines)
        {
            Write-Warning "There are still at least $($oldAvailableMachines.Count) outdated and available machines reported by $($controller.ToUpper())."
            Write-Warning 'Skipping session analysis until available machines are all up-to-date.'
            $sessions = @()
        }

        else
        {
            Write-Verbose "Analyzing sessions and vDisks on $($controller.ToUpper()) (this may take a minute)..."
            Write-Progress -Activity 'Pulling session list' -Status $controller

            $sessionParams = @{
                AdminAddress     = $controller
                DesktopGroupName = $DeliveryGroup
                DesktopKind      = 'Shared'
                MaxRecordCount   = $MaxRecordCount
            }

            $sessions = Get-BrokerSession @sessionParams

            Write-Progress -Activity 'Pulling session list' -Completed
        }

        if ($sessions)
        {
            Write-Progress -Activity "Querying $($sessions.Length) desktops for vDisk information (${TimeOut} sec timeout)." -Status $controller

            $lookupParams = @{
                ComputerName     = $sessions.HostedMachineName
                Timeout          = $Timeout
                RegistryKey      = $RegistryKey
                RegistryProperty = $RegistryProperty

            }
            $vDiskLookup = Get-VDiskInfo @lookupParams

            Write-Progress -Activity "Querying $($sessions.Length) desktops for vDisk information (${TimeOut} sec timeout)." -Completed
            
            # Now we can loop through the sessions and handle them accordingly
            foreach ($session in $sessions)
            {
                try   { $vDisk = $vDiskLookup[$session.HostedMachineName] }
                catch { $vDisk = $null }

                $statusParams = @{
                    TargetVersionPattern = $TargetVersionPattern
                    AllVersionsPattern   = $AllVersionsPattern
                    DiskName             = $vDisk
                }

                $updateStatus = Get-UpdateStatus @statusParams

                # Propose an action based on update status
                switch ($updateStatus)
                {
                    'RestartRequired'
                    {
                        $isInactive = $session.SessionState -ne 'Active'
                        $hasntChangedInAWhile = $session.SessionStateChangeTime -lt (Get-Date).AddHours( - $MaxHoursIdle)

                        if ($isInactive -and $hasntChangedInAWhile)
                        {
                            # Needs a restart, and they aren't using it
                            $proposedAction = [ProposedAction]::Restart
                        }
                        else
                        {
                            # Needs a restart, but they could be using it (it's either active, or was recently active)
                            $proposedAction = [ProposedAction]::Nag
                        }
                    }

                    default
                    {
                        # No action needed (or not enough info to propose an action)
                        $proposedAction = [ProposedAction]::None
                    }
                }

                # Summarize this session
                [pscustomobject]@{
                    HostedMachineName      = $session.HostedMachineName
                    DiskName               = $vDisk
                    UpdateStatus           = $updateStatus
                    ProposedAction         = $proposedAction
                    SessionState           = $session.SessionState
                    SessionStateChangeTime = $session.SessionStateChangeTime
                    Uid                    = $session.Uid
                    AdminAddress           = $controller.ToUpper()
                }
            }
        }
        else
        {
            Write-Verbose "No interesting sessions found on $($controller.ToUpper())."
        }
        $elapsed = [int]((Get-Date) - $analysisStart).TotalSeconds
        Write-Verbose "Completed $($controller.ToUpper()) session analysis in ${elapsed} seconds."
    }

    if ($sessionReport)
    {
        'Session Summary' | Out-Header -Double
        $sessionReport | Format-Table -AutoSize
    }
}
#endregion Analysis


#region Actions


# Randomize the report order so we get some distribution across sites.
# TODO: Write a helper function to sort (round-robin across sites by action).
$sessionReport          = $sessionReport          | Sort-Object {Get-Random}
$availableMachineReport = $availableMachineReport | Sort-Object {Get-Random}


# Restart available outdated machines
foreach ($availableMachineInfo in $availableMachineReport)
{
    switch ($availableMachineInfo.ProposedAction)
    {
        'Restart'
        {
            # Make sure the machine is still available before we reboot it.
            $refreshParams = @{
                AdminAddress      = $availableMachineInfo.AdminAddress
                HostedMachineName = $availableMachineInfo.HostedMachineName
            }

            $currentMachine = Get-BrokerMachine @refreshParams

            if ($currentMachine.SummaryState -ne 'Available')
            {
                Write-Warning "$($currentMachine.HostedMachineName) is no longer available ($($currentMachine.SummaryState)). Skipping."
            }

            else
            {
                if (($restartCount -lt $MaxRestartActions) -and ($whatIfRestartCount -lt $MaxRestartActions))
                {
                    if ($PSCmdlet.ShouldProcess("$($availableMachineInfo.HostedMachineName) (Available: No Session)", 'RESTART MACHINE'))
                    {
                        $restartParams = @{
                            AdminAddress = $availableMachineInfo.AdminAddress
                            MachineName  = $currentMachine.MachineName
                            Action       = 'Restart'
                            ErrorAction  = 'Stop'
                        }

                        try
                        {
                            $asyncTask = New-BrokerHostingPowerAction @restartParams
                            $taskName  = "$($asyncTask.Uid)@$($restartParams.AdminAddress)"
                            
                            $asyncTasks.Add($taskName) > $null
                            Write-Verbose "Task: ${taskName}"
                            $restartCount++
                        }
                        catch
                        {
                            Write-Warning $_.Exception.Message
                            $restartFailCount++
                        }
                    }
                    else
                    {
                        $whatIfRestartCount++
                        $whatIfTracker.Add($availableMachineInfo) > $null
                    }
                } 
            }
        } 
    }
}

# Restart and/or nag sessions on outdated machines
foreach ($sessionInfo in $sessionReport)
{
    switch ($sessionInfo.ProposedAction)
    {
        'Restart'
        {
            # Verify it's still inactive before restarting
            $refreshParams = @{
                AdminAddress      = $sessionInfo.AdminAddress
                HostedMachineName = $sessionInfo.HostedMachineName
            }

            $currentSession = Get-BrokerSession @refreshParams

            if ($currentSession.SessionState -ne 'Active')
            {
                if (($restartCount -lt $MaxRestartActions) -and ($whatIfRestartCount -lt $MaxRestartActions))
                {
                    if ($PSCmdlet.ShouldProcess("$($sessionInfo.HostedMachineName) (Inactive Session)", 'RESTART MACHINE'))
                    {
                        $restartParams = @{
                            AdminAddress = $sessionInfo.AdminAddress
                            MachineName  = $currentSession.MachineName
                            Action       = 'Restart'
                            ErrorAction  = 'Stop'
                        }

                        try
                        {
                            $asyncTask = New-BrokerHostingPowerAction @restartParams
                            $taskName  = "$($asyncTask.Uid)@$($restartParams.AdminAddress)"
                            
                            $asyncTasks.Add($taskName) > $null
                            Write-Verbose "Task: ${taskName}"
                            $restartCount++
                        }
                        catch
                        {
                            Write-Warning $_.Exception.Message
                            $restartFailCount++
                        }
                    }
                    else
                    {
                        $whatIfRestartCount++
                        $whatIfTracker.Add($sessionInfo) > $null
                    }
                }
            } 

            # It's active now, we'll nag instead.
            else
            {
                $nagParams = @{
                    AdminAddress      = $sessionInfo.AdminAddress
                    HostedMachineName = $sessionInfo.HostedMachineName
                    SessionUID        = $sessionInfo.Uid
                    Title             = $NagTitle
                    Text              = $NagText
                }
                
                Send-Nag @nagParams
            }
        } # 'Restart'

        'Nag'
        {
            $nagParams = @{
                AdminAddress      = $sessionInfo.AdminAddress
                HostedMachineName = $sessionInfo.HostedMachineName
                SessionUID        = $sessionInfo.Uid
                Title             = $NagTitle
                Text              = $NagText
            }

            Send-Nag @nagParams
        }
    }
}
#endregion Actions


#region Monitor

# Unless otherwise specified, wait for power actions to complete before exiting script.
if (-not $RunAsync)
{
    $startingTaskCount = $asyncTasks.Count
    $stopWatch = [Diagnostics.StopWatch]::StartNew()
    
    $activity   = 'Waiting for power actions to complete'
    $activityId = 10
    $progressParams = @{
        Activity = $activity
        Status   = "Querying ${startingTaskCount} tasks"
        Id       = $activityId
    }
    Write-Progress @progressParams

    while ($asyncTasks -and ($stopWatch.Elapsed.TotalSeconds -lt $PowerActionTimeout))
    {
        $asyncTasks = @($asyncTasks | Get-PendingPowerAction)

        if ($asyncTasks)
        {
            $completedTaskCount = $startingTaskCount - $asyncTasks.Count
            $pctComplete = 100 * ($completedTaskCount / $startingTaskCount)
            
            # Update the "elapsed" time on the progress bar each second, but 
            # don't re-query anything for another 5 seconds.
            for ($i = 1; $i -le 5; $i++)
            {
                $elapsed = $stopWatch.Elapsed.ToString("mm\:ss")
                
                $progressParams = @{
                    PercentComplete = $pctComplete
                    Id              = $activityId
                    Activity        = $activity
                    Status          = "${completedTaskCount}/${startingTaskCount} (${elapsed} elapsed)"
                }
                Write-Progress @progressParams

                Start-Sleep -Seconds 1
            }
        }
    }

    if ($asyncTasks)
    {
        Write-Warning "$($asyncTasks.Count) tasks still pending after ${PowerActionTimeout} seconds!"
        Write-Warning "The following power actions are still queued, but their"
        Write-Warning "progress will not be monitored:"
        $asyncTasks | Write-Warning
    }

    Write-Progress -Activity $activity -Id $activityId -Completed
    $stopWatch.Stop()
}
#endregion Monitor


#region Summary
$combinedReport = $sessionReport + $availableMachineReport

'Final Summary' | Out-Header -Double

foreach ($property in 'UpdateStatus', 'ProposedAction', 'DiskName')
{
    $property | Out-Header 

    $combinedReport | 
        Group-Object -Property $property -NoElement |
        Select-Object -Property Count, @{ n = $property; e = { $_.Name } } |
        Sort-Object -Property 'Count' -Descending |
        Format-Table -HideTableHeaders
}

$elapsedSeconds = [int]((Get-Date) - $scriptStart).TotalSeconds
"Total Nags Sent: ${nagCount} (${nagFailCount} failed)"
"Total Restarts Requested: ${restartCount} (${restartFailCount} failed, $($asyncTasks.Count) pending)."
"Script completed in ${elapsedSeconds} seconds."
#endregion Summary
