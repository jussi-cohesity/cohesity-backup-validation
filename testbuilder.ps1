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
task startCloneTask {

    if (!$Environment.vmwareServer) { throw "Clone task failed. VMware Server is not defined in environment json-file"  }
    if (!$Environment.vmwareResourcePool) { throw "Clone task failed. VMware Resource Pool is not defined in config json-file" }

    # Get vmware source ID for resource pool
    $vmwareSource = Get-CohesityProtectionSourceObject -Environments kVMware | Where-Object Name -eq $Environment.vmwareServer 
    $vmwareResourcePool = Get-CohesityProtectionSourceObject -Environments kVMware | Where-Object ParentId -eq $($vmwareSource.Id) | Where-Object Name -eq $Environment.vmwareResourcePool 

    if (!$vmwareSource) {
        throw "Couldnt find Protection Source $($Environment.vmwareServer). Failing tests. Please check!"
    }

    [Array]$Script:clones = $null
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
        $Script:clones += $cloneTask
    }
}
### Validate status of Clone Task and Power State of VM
task cloneTaskStatus {
    foreach ($clone in $clones) {
        while ($true) {
            $validateTask = (Get-CohesityRestoreTask -Id $clone.Id).Status
            $validatePowerOn = (Get-VM -Name $clone.Name -ErrorAction:SilentlyContinue).PowerState
            Start-Sleep 10
            Write-Host "$($clone.Name) clone status is $validateTask and Power Status is $ValidatePowerOn" -ForegroundColor Yellow
            if ($validateTask -eq 'kFinished' -and $validatePowerOn -eq 'PoweredOn') {
                break
            } elseif ($sleepCount -gt '20') {
                throw "Clone of VM $($clone.Name) failed. Failing tests. Other cloned VMs remain cloned status, manual cleanup might needed!"
            } else {
                Start-Sleep 15
                $sleepCount++
            }
        }
    }
}

### Check the status of VMware Tools in Cloned VMs
task vmwareToolsStatus {
    foreach ($clone in $clones) {
        while ($true) {
            $toolStatus = (Get-VM -Name $clone.Name).ExtensionData.Guest.ToolsRunningStatus
            
            Write-Host "VM $($clone.Name) VMware Tools Status is $toolStatus" -ForegroundColor Yellow
            if ($toolStatus -ne 'guestToolsRunning') {
                Start-Sleep 15
            } else {
                break
            }
        }
    }
}

task vmScriptTest {
    $i = 0
    foreach ($clone in $clones) {
        $vmCredentials = Import-Clixml -Path ($Config.virtualMachines[$i].guestCred)
        $loopCount = 1
        while ($true) {
            Write-Host "Run try ($loopCount)/5: Script test on $($clone.name)" -ForegroundColor Yellow

            if ($Config.virtualMachines[$i].guestOS -eq 'Windows') {
                $vmscript = @{
                    ScriptText      = 'hostname'
                    ScriptType      = 'PowerShell'
                    VM              = $clone.name
                    GuestCredential = $vmCredentials
                }
            }
            
            if ($Config.virtualMachines[$i].guestOS -eq 'Linux') {
                $vmscript = @{
                    ScriptText      = 'hostname'
                    ScriptType      = 'bash'
                    VM              = $clone.name
                    GuestCredential = $vmCredentials
                }
            }

            try {
                Invoke-VMScript @vmscript -ErrorAction Stop
                break
            } catch { }
            
            $loopCount++
            Start-Sleep 5
            
            if ($LoopCount -gt 5) {
                Write-Host "Could not execute script on $($clone.Name), failing tests!" -ForegroundColor Red
                Exit
            }
        }
        $i++
    }

}

### Config network for cloned VMs
task configVMNetwork {
    $i = 0
    foreach ($clone in $clones) {
        $network  = $Config.virtualMachines[$i].testNetwork
        $results = Get-VM $clone.Name | Select-Object -first 1 | New-NetworkAdapter -NetworkName $Config.virtualMachines[$i].testNetwork -StartConnected:$true
        Write-Host "Virtual machine $($clone.name) attached to network $network. Waiting 30 seconds before next step!" -ForegroundColor Yellow
        Start-Sleep 30
        $i++
    }
}

### Change VM network IPs to test IPs
task configVMNetworkIP {
    $i = 0
    foreach ($clone in $clones) {
        Write-Host "$($clone.Name): Importing credential file $($Config.virtualMachines[$i].guestCred))" -ForegroundColor Yellow
        $vmCredentials = Import-Clixml -Path ($Config.virtualMachines[$i].guestCred)

        if ($Config.virtualMachines[$i].guestOS -eq 'Windows') {
            $TestInterfaceMAC = ((Get-NetworkAdapter -VM $($clone.Name) | Select-Object -first 1).MacAddress).ToLower() -replace ":","-"
            $run = @{
                ScriptText      = 'Get-NetAdapter | where {($_.MacAddress).ToLower() -eq "' + $TestInterfaceMAC + '"} | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue;`
                                Get-NetAdapter | where {($_.MacAddress).ToLower() -eq "' + $TestInterfaceMAC + '"} | Get-NetIPAddress | Remove-NetIPAddress -confirm:$false;`
                                Get-NetAdapter | where {($_.MacAddress).ToLower() -eq "' + $TestInterfaceMAC + '"} | `
                                New-NetIPAddress -IPAddress ' + $Config.virtualMachines[$i].testIp + ' -PrefixLength ' + $Config.virtualMachines[$i].testSubnet + `
                                ' -DefaultGateway ' + $Config.virtualMachines[$i].testGateway
                ScriptType      = 'PowerShell'
                VM              = $clone.Name
                GuestCredential = $vmCredentials
            }
         
        } elseif ($Config.virtualMachines[$i].guestOS -eq 'Linux')  {
            $run = @{
                ScriptText      = 'ifconfig "' + $($Config.virtualMachines[$i].linuxNetDev) + '" "' + $($Config.virtualMachines[$i].testIp) + '"/"' + $($Config.virtualMachines[$i].testSubnet) + '" up && route add default gw "' + $Config.virtualMachines[$i].testGateway + '" ' 
                ScriptType      = 'bash'
                VM              = $clone.Name
                GuestCredential = $vmCredentials
            } 
        } else { 
            Write-Host "$($clone.Name): Network IP change to $($Config.virtualMachines[$i].testIp) failed. GuestOS $($Config.virtualMachines[$i].guestOS) is not supported (Windows/Linux). Cloned VMs remain cloned status, manual cleanup might needed!" -ForegroundColor Red
            exit
        }

        $output = Invoke-VMScript @run -ErrorAction Stop
        $i++
    }
}

### Run backup validation tests defined in configuration json per VM
task doValidationTests {
    $i = 0
    foreach ($clone in $clones) {
        Write-Host "$($clone.Name): Running tests $($Config.virtualMachines[$i].tests)" -ForegroundColor Yellow
        $vmCredentials = Import-Clixml -Path ($Config.virtualMachines[$i].guestCred)
        Invoke-Build -File .\validationTests.ps1 -Tests $Config.virtualMachines[$i].tests -Config $Config.virtualMachines[$i] -vmCredentials $vmCredentials -vmName $($Clone.Name)
        Write-Host "$($clone.Name): Testing complete" -ForegroundColor Yellow
        $i++
    }
}

### After testing remove clones
task removeClones {
    foreach ($clone in $clones) {
        $removeRequest = Remove-CohesityClone -TaskId $clone.id -Confirm:$false
        Write-Host "$($clone.Name): $removeRequest" -ForegroundColor Yellow

        $removeView = Remove-CohesityView -Name $clone.name -Confirm:$false
        Write-Host "Removing view $($clone.name)" -ForegroundColor Yellow
    }
}

task 1_OpenConnection `
getConfig
connectCohesity,
connectVMware

task 2_CloneVMs `
startCloneTask,
cloneTaskStatus,
vmwareToolsStatus,
vmScriptTest

task 3_ChangeVMNetwork `
configVMNetwork,
configVMNetworkIP

task 4_DoTesting `
doValidationTests

task 5_Cleanup `
removeClones

task . `
1_OpenConnection,
2_CloneCMs,
3_ChangeVMNetwork,
4_DoTesting,
5_Cleanup
