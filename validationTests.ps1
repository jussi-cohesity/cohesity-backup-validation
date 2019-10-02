###
### Helper tool to specify all possible application tests - Jussi Jaurola <jussi@cohesity.com>
###
### This sample contains only three tests but more tests can be added and tests can be assigned per vm on configuration files
###

param(
    $Config,
    [System.Management.Automation.PSCredential]$vmCredentials,
    $vmName
)

task Ping {
    $results = (Test-Connection -ComputerName $Config.testIp -Quiet)

    if ($results -eq $true) { 
        Write-Host "Task ping for host $($Config.name) passed!" -ForegroundColor Yellow
    }

    if ($results -eq $false) {
        Write-Host "Task ping for host $($Config.name) failed!" -ForegroundColor Red
    }
    
}

task MySQLStatus {
    $run = @{
        VM              = $vmName
        GuestCredential = $vmCredentials
        ScriptType        = 'bash'
        ScriptText      = "service mysqld status"
    }
    $results = Invoke-VMScript @run
    Write-Host "$vmName MySQL Status: $results"
}

task getWindowsServicesStatus {
    $run = @{
        ScriptText      = 'Get-Service'
        ScriptType      = 'PowerShell'
        VM              = $vmName
        GuestCredential = $vmCredentials
    }
    $results = Invoke-VMScript @run -ErrorAction Stop

    Write-Host "$vmName service status: $results"
}

task getLinuxServiceStatus {
    $run = @{
        ScriptText      = 'service --status-all'
        ScriptType      = 'bash'
        VM              = $vmName
        GuestCredential = $vmCredentials
    }
    $results = Invoke-VMScript @run -ErrorAction Stop

    Write-Host "$vmName service status: $results"
}

task .
