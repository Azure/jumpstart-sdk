function Set-NICs {
    Param (
        $LocalBoxConfig,
        [PSCredential]$Credential
    )

    Invoke-Command -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Credential $Credential -ScriptBlock {
        Get-NetAdapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN"}).Name) | Rename-NetAdapter -NewName FABRIC
    }

    foreach ($VM in $LocalBoxConfig.NodeHostConfig) {

        Write-Host "Setting NICs on VM $($VM.Hostname)"
        Invoke-CommandWithRetry -VMName $VM.Hostname -Credential $Credential -MaxRetries 12 -RetryDelay 10 -ScriptBlock {

            # Set Name and IP Addresses on Storage Interfaces
            $storageNICs = Get-NetAdapterAdvancedProperty | Where-Object { $_.DisplayValue -match "Storage" }
            foreach ($storageNIC in $storageNICs) {
                Rename-NetAdapter -Name $storageNIC.Name -NewName  $storageNIC.DisplayValue -PassThru | Select-Object Name,PSComputerName
            }
            $storageNICs = Get-Netadapter | Where-Object { $_.Name -match "Storage" }

            # Rename non-storage adapters
            Get-NetAdapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN"}).Name) | Rename-NetAdapter -NewName FABRIC -PassThru | Select-Object Name,PSComputerName

        }
    }
}
