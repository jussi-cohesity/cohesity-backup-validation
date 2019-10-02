###
### Helper tool to create encrypted credential files - Jussi Jaurola <jussi@cohesity.com>
###

$credTypes = @("cohesity_cred.xml","vmware_cred.xml","guestvm_cred.xml")

foreach ($cred in $credTypes) {
    $Credential = Get-Credential -Message $cred
    $Credential | Export-Clixml -Path $cred
}
