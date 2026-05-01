function New-RouterVM {
    Param (
        $LocalBoxConfig,
        [PSCredential]$localCred
    )
    $Unattend = GenerateAnswerFile -Hostname $LocalBoxConfig.BGPRouterName -IsRouterVM $true -LocalBoxConfig $LocalBoxConfig
    Invoke-Command -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Credential $localCred -ScriptBlock {
        $LocalBoxConfig = $using:LocalBoxConfig
        $localCred = $using:localcred
        $ParentDiskPath = "C:\VMs\Base\GUI.vhdx"
        $vmpath = "D:\VMs\"
        $VMName = $LocalBoxConfig.BGPRouterName

        # Create Host OS Disk
        Write-Host "Creating $VMName differencing disks"
        New-VHD -ParentPath $ParentDiskPath -Path ($vmpath + $VMName + '\' + $VMName + '.vhdx') -Differencing | Out-Null

        # Create VM
        Write-Host "Creating the $VMName VM."
        New-VM -Name $VMName -VHDPath ($vmpath + $VMName + '\' + $VMName + '.vhdx') -Path ($vmpath + $VMName) -Generation 2 | Out-Null

        # Set VM Configuration
        Write-Host "Setting $VMName's VM Configuration"
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true -StartupBytes $LocalBoxConfig.MEM_BGP -MinimumBytes 500MB -MaximumBytes $LocalBoxConfig.MEM_BGP | Out-Null
        Remove-VMNetworkAdapter -VMName $VMName -Name "Network Adapter" | Out-Null
        Set-VMProcessor -VMName $VMName -Count 2 | Out-Null
        Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStopAction ShutDown -AutomaticStartDelay 0 | Out-Null

        # Configure VM Networking
        Write-Host "Configuring $VMName's Networking"
        Add-VMNetworkAdapter -VMName $VMName -Name Mgmt -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name Provider -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name VLAN110 -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name VLAN200 -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name SIMInternet -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming On
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName Provider -Access -VlanId $LocalBoxConfig.providerVLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName VLAN110 -Access -VlanId $LocalBoxConfig.vlan110VLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName VLAN200 -Access -VlanId $LocalBoxConfig.vlan200VLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName SIMInternet -Access -VlanId $LocalBoxConfig.simInternetVLAN
        Add-VMNetworkAdapter -VMName $VMName -Name NAT -SwitchName NAT -DeviceNaming On

        # Mount disk and inject Answer File
        Write-Host "Mounting Disk Image and Injecting Answer File into the $VMName VM."
        New-Item -Path "C:\TempBGPMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempBGPMount" -Index 1 -ImagePath ($vmpath + $VMName + '\' + $VMName + '.vhdx') | Out-Null
        New-Item -Path C:\TempBGPMount\windows -ItemType Directory -Name Panther -Force | Out-Null
        Set-Content -Value $using:Unattend -Path "C:\TempBGPMount\Windows\Panther\Unattend.xml" -Force

        # Enable remote access
        Write-Host "Enabling Remote Access"
        Enable-WindowsOptionalFeature -Path C:\TempBGPMount -FeatureName RasRoutingProtocols -All -LimitAccess | Out-Null
        Enable-WindowsOptionalFeature -Path C:\TempBGPMount -FeatureName RemoteAccessPowerShell -All -LimitAccess | Out-Null
        Write-Host "Dismounting Disk Image for $VMName VM."
        Dismount-WindowsImage -Path "C:\TempBGPMount" -Save | Out-Null
        Remove-Item "C:\TempBGPMount"

        # Start the VM
        Write-Host "Starting $VMName VM."
        Start-VM -Name $VMName

        # Wait for VM to be started
        while ((Invoke-Command -VMName $VMName -Credential $localcred { "Test" } -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 1 }

        Write-Host "Configuring $VMName"
        Invoke-Command -VMName $VMName -Credential $localCred -ArgumentList $LocalBoxConfig -ScriptBlock {
            $LocalBoxConfig = $args[0]
            $DNS = $LocalBoxConfig.SDNLABDNS
            $natSubnet = $LocalBoxConfig.natSubnet
            $natDNS = $LocalBoxConfig.natSubnet
            $MGMTIP = $LocalBoxConfig.BGPRouterIP_MGMT.Split("/")[0]
            $MGMTPFX = $LocalBoxConfig.BGPRouterIP_MGMT.Split("/")[1]
            $PNVIP = $LocalBoxConfig.BGPRouterIP_ProviderNetwork.Split("/")[0]
            $PNVPFX = $LocalBoxConfig.BGPRouterIP_ProviderNetwork.Split("/")[1]
            $VLANIP = $LocalBoxConfig.BGPRouterIP_VLAN200.Split("/")[0]
            $VLANPFX = $LocalBoxConfig.BGPRouterIP_VLAN200.Split("/")[1]
            $VLAN110IP = $LocalBoxConfig.BGPRouterIP_VLAN110.Split("/")[0]
            $VLAN110PFX = $LocalBoxConfig.BGPRouterIP_VLAN110.Split("/")[1]
            $simInternetIP = $LocalBoxConfig.BGPRouterIP_SimulatedInternet.Split("/")[0]
            $simInternetPFX = $LocalBoxConfig.BGPRouterIP_SimulatedInternet.Split("/")[1]

            # Renaming NetAdapters and setting up the IPs inside the VM using CDN parameters
            Write-Host "Configuring $env:COMPUTERNAME's Networking"
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "Mgmt" }
            Rename-NetAdapter -name $NIC.name -newname "Mgmt" | Out-Null
            New-NetIPAddress -InterfaceAlias "Mgmt" -IPAddress $MGMTIP -PrefixLength $MGMTPFX | Out-Null
            Set-DnsClientServerAddress -InterfaceAlias “Mgmt” -ServerAddresses $DNS | Out-Null

            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "PROVIDER" }
            Rename-NetAdapter -name $NIC.name -newname "PROVIDER" | Out-Null
            New-NetIPAddress -InterfaceAlias "PROVIDER" -IPAddress $PNVIP -PrefixLength $PNVPFX | Out-Null

            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN200" }
            Rename-NetAdapter -name $NIC.name -newname "VLAN200" | Out-Null
            New-NetIPAddress -InterfaceAlias "VLAN200" -IPAddress $VLANIP -PrefixLength $VLANPFX | Out-Null

            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN110" }
            Rename-NetAdapter -name $NIC.name -newname "VLAN110" | Out-Null
            New-NetIPAddress -InterfaceAlias "VLAN110" -IPAddress $VLAN110IP -PrefixLength $VLAN110PFX | Out-Null

            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "SIMInternet" }
            Rename-NetAdapter -name $NIC.name -newname "SIMInternet" | Out-Null
            New-NetIPAddress -InterfaceAlias "SIMInternet" -IPAddress $simInternetIP -PrefixLength $simInternetPFX | Out-Null

            # Configure NAT
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "NAT" }
            Rename-NetAdapter -name $NIC.name -newname "NAT" | Out-Null
            $Prefix = ($natSubnet.Split("/"))[1]
            $natIP = ($natSubnet.TrimEnd("0./$Prefix")) + (".10")
            $natGW = ($natSubnet.TrimEnd("0./$Prefix")) + (".1")
            New-NetIPAddress -InterfaceAlias "NAT" -IPAddress $natIP -PrefixLength $Prefix -DefaultGateway $natGW | Out-Null
            if ($natDNS) {
                Set-DnsClientServerAddress -InterfaceAlias "NAT" -ServerAddresses $natDNS | Out-Null
            }

            # Configure Trusted Hosts
            Write-Host "Configuring Trusted Hosts on $env:COMPUTERNAME"
            Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force

            # Installing Remote Access
            Write-Host "Installing Remote Access on $env:COMPUTERNAME"
            Install-RemoteAccess -VPNType RoutingOnly | Out-Null

            # Adding a BGP Router to the VM
            # Write-Host "Creating BGP Router on $env:COMPUTERNAME"
            # Add-BgpRouter -BGPIdentifier $PNVIP -LocalASN $LocalBoxConfig.BGPRouterASN -TransitRouting 'Enabled' -ClusterId 1 -RouteReflector 'Enabled'

            # Configure BGP Peers - commented during refactor for 23h2
            # if ($LocalBoxConfig.ConfigureBGPpeering -and $LocalBoxConfig.ProvisionNC) {
            #     Write-Verbose "Peering future MUX/GWs"
            #     $Mux01IP = ($LocalBoxConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "4"
            #     $GW01IP = ($LocalBoxConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "5"
            #     $GW02IP = ($LocalBoxConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "6"
            #     $params = @{
            #         Name           = 'MUX01'
            #         LocalIPAddress = $PNVIP
            #         PeerIPAddress  = $Mux01IP
            #         PeerASN        = $LocalBoxConfig.SDNASN
            #         OperationMode  = 'Mixed'
            #         PeeringMode    = 'Automatic'
            #     }
            #     Add-BgpPeer @params -PassThru
            #     $params.Name = 'GW01'
            #     $params.PeerIPAddress = $GW01IP
            #     Add-BgpPeer @params -PassThru
            #     $params.Name = 'GW02'
            #     $params.PeerIPAddress = $GW02IP
            #     Add-BgpPeer @params -PassThru
            # }

       }
    }
}
