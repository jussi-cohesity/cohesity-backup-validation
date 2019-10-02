###
### Helper tool to build backup validation testing for VMs - Jussi Jaurola <jussi@cohesity.com>
###

param (
    [Parameter(Mandatory=$true)][ValidateScript({Test-Path $_})][String]$EnvironmentFile,
    [Parameter(Mandatory=$true)][ValidateScript({Test-Path $_})][String]$ConfigFile
)

### Get  configuration from config.json for future reference use
task getConfig {
    $script:Environment = Get-Content -Path $EnvironmentFile | ConvertFrom-Json
    $script:Config = Get-Content -Path $ConfigFile | ConvertFrom-Json
}

### Connect to Cohesity cluster
task connectCohesity {
    Write-Host "Importing Credential file: $($Environment.cohesityCred)" -ForegroundColor Yellow
    Write-Host "Connecting to Cohesity Cluster $($Environment.cohesityCluster)" -ForegroundColor Yellow
    $Credential = Import-Clixml -Path ($Environment.cohesityCred)
    try {
        Connect-CohesityCluster -Server $Environment.cohesityCluster -Credential $Credential
        Write-Host "Connected to Cohesity Cluster $($Environment.cohesityCluster)" -ForegroundColor Yellow
    } catch {
        write-host "Cannot connect to Cohesity cluster $($Environment.cohesityCluster)" -ForegroundColor Yellow
        exit
    }
}

### Connect to VMware vCenter
task connectVMware {
    Write-Host "Getting credentials from credential file $($Environment.vmwareCred)" -ForegroundColor Yellow
    $Credential = Import-Clixml -Path ($Environment.vmwareCred)
    try {
        Connect-VIServer -Server $Environment.vmwareServer -Credential $Credential
        Write-Host "Connected to VMware vCenter $($global:DefaultVIServer.Name)" -ForegroundColor Yellow
    } catch {
        write-host "Cannot connect to VMware vCenter $($Environment.vmwareServer)" -ForegroundColor Yellow
        exit
    }
}

### Create a clone task for virtual machine(s)
task createCloneTask {

    if (!$Environment.vmwareServer) { throw "Clone task failed. VMware Server is not defined in environment json-file"  }
    if (!$Environment.vmwareResourcePool) { throw "Clone task failed. VMware Resource Pool is not defined in config json-file" }

    # Get vmware source ID for resource pool
    $vmwareSource = Get-CohesityProtectionSourceObject -Environments kVMware | Where-Object Name -eq $Environment.vmwareServer 
    $vmwareResourcePool = Get-CohesityProtectionSourceObject -Environments kVMware | Where-Object ParentId -eq $($vmwareSource.Id) | Where-Object Name -eq $Environment.vmwareResourcePool 

    if (!$vmwareSource) {
        throw "Couldnt find Protection Source $($Environment.vmwareServer). Failing tests. Please check!"
    }

    [Array]$Script:CloneArray = $null
    foreach ($VM in $Config.virtualMachines) {  
        if (!$VM.backupJobName) { throw "Clone task failed. Bckupjob is not defined for VM $($VM.name)" }
        ### if multiple objects found with same object name, use first
        $backupJob =  Find-CohesityObjectsForRestore -Search $($VM.name) -environments kVMware | Where-Object JobName -eq $($VM.backupJobName) | Select-Object -first 1 
        $cloneVM = Get-CohesityVMwareVM -name $VM.name 
        $taskName = $($VM.vmNamePrefix) + "" + $($VM.name)  
        if (!$cloneVM) {
            Write-Host "Couldnt find VM $($VM.name). Failing tests. Please check!" -ForegroundColor Red
            exit
        }
        $cloneTask = Copy-CohesityVMwareVM -TaskName $taskName -PoweredOn:$true -DisableNetwork:$false -Jobid $($backupJob.JobId) -SourceId $($cloneVM.id) -TargetViewName $taskName -VmNamePrefix "$($VM.vmNamePrefix)" -ResourcePoolId $($vmwareResourcePool.id) -NewParent $($vmwareSource.Id)
        Write-Host "Created cloneTask $($cloneTask.Id) for VM $($VM.name)" -ForegroundColor Yellow
        $Script:CloneArray += $cloneTask
    }
}
### Validate sstatus of Clone Task and Power State of VM
task checkCloneTask {
    foreach ($Clone in $CloneArray) {
        while ($true) {
            $validateTask = (Get-CohesityRestoreTask -Id $Clone.Id).Status
            $validatePowerOn = (Get-VM -Name $Clone.Name -ErrorAction:SilentlyContinue).PowerState
            Start-Sleep 10
            Write-Host "$($Clone.Name) clone status is $validateTask and Power Status is $ValidatePowerOn" -ForegroundColor Yellow
            if ($validateTask -eq 'kFinished' -and $validatePowerOn -eq 'PoweredOn') {
                break
            } elseif ($sleepCount -gt '20') {
                throw "Clone of VM $($Clone.Name) failed. Failing tests. Other cloned VMs remain cloned status, manual cleanup might needed!"
            } else {
                Start-Sleep 15
                $sleepCount++
            }
        }
    }
}

### Check the status of VMware Tools in Cloned VMs
task checkVmwareTools {
    foreach ($Clone in $CloneArray) {
        while ($true) {
            $toolStatus = (Get-VM -Name $Clone.Name).ExtensionData.Guest.ToolsRunningStatus
            
            Write-Host "VM $($Clone.Name) VMware Tools Status is $toolStatus" -ForegroundColor Yellow
            if ($toolStatus -ne 'guestToolsRunning') {
                Start-Sleep 15
            } else {
                break
            }
        }
    }
}

task checkPSScriptExecution {
    $i = 0
    foreach ($Clone in $CloneArray) {
        $vmCredentials = Import-Clixml -Path ($Config.virtualMachines[$i].guestCred)
        $loopCount = 1
        while ($true) {
            Write-Host "Run try ($loopCount)/5: Script test on $($Clone.name)" -ForegroundColor Yellow

            if ($Config.virtualMachines[$i].guestOS -eq 'Windows') {
                $vmscript = @{
                    ScriptText      = 'hostname'
                    ScriptType      = 'PowerShell'
                    VM              = $Clone.name
                    GuestCredential = $vmCredentials
                }
            }
            
            if ($Config.virtualMachines[$i].guestOS -eq 'Linux') {
                $vmscript = @{
                    ScriptText      = 'hostname'
                    ScriptType      = 'bash'
                    VM              = $Clone.name
                    GuestCredential = $vmCredentials
                }
            }

            try {
                $results = Invoke-VMScript @vmscript -ErrorAction Stop
                Write-Host "checkPSScriptExecution status $results" -ForegroundColor Yellow
                break
            } catch { }
            
            $loopCount++
            Sleep -Seconds 5
            
            if ($LoopCount -gt 5) {
                Write-Host "Could not execute script on $($Clone.Name), failing tests!" -ForegroundColor Red
                Exit
            }
        }
        $i++
    }

}

### Config network for cloned VMs
task configVMNetwork {
    $i = 0
    foreach ($Clone in $CloneArray) {
        $network  = $Config.virtualMachines[$i].testNetwork
        $results = Get-VM $Clone.Name | Select-Object -first 1 | New-NetworkAdapter -NetworkName $Config.virtualMachines[$i].testNetwork -StartConnected:$true
        Write-Host "Virtual machine $($Clone.name) attached to network $network. Waiting 30 seconds before next step!" -ForegroundColor Yellow
        Sleep -Seconds 30
        $i++
    }
}

### Change VM network IPs to test IPs
task configVMNetworkIP {
    $i = 0
    foreach ($Clone in $CloneArray) {
        Write-Host "$($Clone.Name): Importing credential file $($Config.virtualMachines[$i].guestCred))" -ForegroundColor Yellow
        $vmCredentials = Import-Clixml -Path ($Config.virtualMachines[$i].guestCred)

        if ($Config.virtualMachines[$i].guestOS -eq 'Windows') {
            $TestInterfaceMAC = ((Get-NetworkAdapter -VM $($Clone.Name) | Select-Object -first 1).MacAddress).ToLower() -replace ":","-"
            $run = @{
                ScriptText      = 'Get-NetAdapter | where {($_.MacAddress).ToLower() -eq "' + $TestInterfaceMAC + '"} | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue;`
                                Get-NetAdapter | where {($_.MacAddress).ToLower() -eq "' + $TestInterfaceMAC + '"} | Get-NetIPAddress | Remove-NetIPAddress -confirm:$false;`
                                Get-NetAdapter | where {($_.MacAddress).ToLower() -eq "' + $TestInterfaceMAC + '"} | `
                                New-NetIPAddress -IPAddress ' + $Config.virtualMachines[$i].testIp + ' -PrefixLength ' + $Config.virtualMachines[$i].testSubnet + `
                                ' -DefaultGateway ' + $Config.virtualMachines[$i].testGateway
                ScriptType      = 'PowerShell'
                VM              = $Clone.Name
                GuestCredential = $vmCredentials
            }
            $output = Invoke-VMScript @run -ErrorAction Stop
            $run = @{
                ScriptText      = '(Get-NetAdapter| where {($_.MacAddress).ToLower() -eq "' + $TestInterfaceMAC + '"} | Get-NetIPAddress -AddressFamily IPv4).IPAddress'
                ScriptType      = 'PowerShell'
                VM              = $Clone.Name
                GuestCredential = $vmCredentials
            }
        } 

        if ($Config.guestOS -eq 'Linux')  {
            $run = @{
                ScriptText      = 'ifconfig "' + $($Config.virtualMachines[$i].linuxNetDev) + '" "' + $($Config.virtualMachines[$i].testIp) + '"/"' + $($Config.virtualMachines[$i].testSubnet) + '" up && route add default gw "' + $Config.virtualMachines[$i].testGateway + '" ' 
                ScriptType      = 'bash'
                VM              = $Clone.Name
                GuestCredential = $vmCredentials
            } 
        }

        if (!$run) { 
            Write-Host "$($Clone.Name): Network IP change to $($Config.virtualMachines[$i].testIp) failed. GuestOS $($Config.virtualMachines[$i].guestOS) is not supported (Windows/Linux). Cloned VMs remain cloned status, manual cleanup might needed!" -ForegroundColor Red
            exit
        }

        $output = Invoke-VMScript @run -ErrorAction Stop
        $i++
    }
}

### Run backup validation tests defined in configuration json per VM
task validationTests {
    $i = 0
    foreach ($Clone in $CloneArray) {
        Write-Host "$($Clone.Name): Running tests $($Config.virtualMachines[$i].tasks)" -ForegroundColor Yellow
        $vmCredentials = Import-Clixml -Path ($Config.virtualMachines[$i].guestCred)
        Invoke-Build -File .\validationTests.ps1 -Task $Config.virtualMachines[$i].tasks -Config $Config.virtualMachines[$i] -vmCredentials $vmCredentials -vmName $($Clone.Name)
        Write-Host "$($Clone.Name): Testing complete" -ForegroundColor Yellow
        $i++
    }
}

### After testing remove clones
task removeClones {
    foreach ($Clone in $CloneArray) {
        $removeRequest = Remove-CohesityClone -TaskId $Clone.id -Confirm:$false
        Write-Host "$($Clone.Name): $removeRequest"
    }
}

task 1_Init `
getConfig

task 2_Connect `
connectCohesity,
connectVMware

task 3_Clone `
createCloneTask,
checkCloneTask,
checkVmwareTools,
checkPSScriptExecution

task 4_VMNetwork `
configVMNetwork,
configVMNetworkIP

task 5_Testing `
validationTests

task . `
1_Init,
2_Connect,
3_Clone,
4_VMNetwork,
5_Testing,
removeClones
