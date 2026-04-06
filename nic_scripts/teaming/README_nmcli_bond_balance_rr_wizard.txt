nmcli_bond_balance_rr_wizard.sh

Purpose
- Interactive script to create Linux bonding (teaming/bond) on RHEL using NetworkManager.
- Matches validated configuration from your environment:
  * mode: balance-rr (round-robin)
  * xmit_hash_policy: layer2
  * miimon: 1ms
  * IPv4: DHCP by default

Run
  chmod +x nmcli_bond_balance_rr_wizard.sh
  sudo ./nmcli_bond_balance_rr_wizard.sh

Cleanup
  sudo ./nmcli_bond_balance_rr_wizard.sh --cleanup

Notes
- balance-rr typically requires the switch ports to be configured for static port-channel/etherchannel.
- For failover testing without switch configuration, use active-backup mode instead.



Windows
teaming



# Wizard
powershell -ExecutionPolicy Bypass -File .\New-NicTeamingWizard.ps1



# Cleanup wizard-created teams only
powershell -ExecutionPolicy Bypass -File .\New-NicTeamingWizard.ps1 -Cleanup
