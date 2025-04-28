# TrueNAS ZFS over iSCSI Plugin for Proxmox VE

## 📢: ATTENTION 2025-04-28 📢: New repos are now online at [Cloudsmith](#new-installs).

## Activity

<details>
 <summary>Expand to see the activity tree</summary>

 <blockquote>
  
  <details><summary>2025-04-28</summary>
  
  - Fork repository to begin update work 
  - Remove donation link from readme
  
  </details>

  <details><summary>2023-08-18</summary>

  - Update and cleanup the README.md

  </details>

  <details><summary>2023-08-12</summary>
   
  - Fixed postinst issue with Windows-based EOL. https://github.com/TheGrandWazoo/freenas-proxmox/issues/149

  </details>

  <details><summary>2023-02-12</summary>
   
  - Added `systemctl restart pvescheduler.service` command to the package based on https://github.com/TheGrandWazoo/freenas-proxmox/issues/109#issuecomment-1367527917

  </details>

  </blockquote>
</details>

## Roadmap
<details><summary>Roadmap details</summary>

* Change FreeNAS references to TrueNAS - <i> Implemented, Pending Testing</i>.
* Fork freenas-proxmox-packer and set up - <i> Completed, Pending Testing</i>.
* Port wiki to new fork
* Set up new Cloudsmith repo for new fork
* Optimize code with ChatGPT/Copilot
* Fix iSCSI errors
  * Fix iSCSI errors https://github.com/TheGrandWazoo/freenas-proxmox/issues/203
* Update REST API to fix deprecations
  * https://github.com/TheGrandWazoo/freenas-proxmox/issues/205
* Update the documentation - <i>In Progress</i>.
  * Restructure the main README.md for better readability. 
  * Add some screenshots.
* Fix Max Lun Limit issue.
  * https://github.com/TheGrandWazoo/freenas-proxmox/issues/150
* Fix automated builds - <i>In Progress</i>.
  * Production - 'main' repo component.
* Autoinstall the SSH keys.
  * Tech spike to see if it is even doable.
* Hashicorp Vault integration.
  * Pull in secrets from a Hashicorp Vault service.  
  * Tech spike to see if it is even doable.
* Package the patches with the deb package.
  * Remove the need for git dependency.
* Change to LWP::UserAgent
  * Remove dependency of the REST::Client because LWP::UserAgent is already installed and used by Proxmox VE.
* Add API key for direct TrueNAS services - <i>In Progress</i>.
  * Will be a new enable field and API key and will only be used by the plugin.
  * You will still need the SSH keys, username, and password because of Proxmox VE using `iscsiadm` to get the list of disks.
    * This is tricky because the format needs to be that of the output of 'zfs list' which is not part of the LunCmd but that of the backend Proxmox VE system and the API's do a bunch of JSON stuff.

</details>

## New Install Instructions

### Select at least one `Step 1.x` based on your preference. Can be combined.

<details><summary>Step 1.0: For stable releases. <b>Enabled</b> by default.</summary>

 ### truenas-proxmox repo - Currently follows the 2.0 branch.

 Select one of the following GPG Key locations based on your preference.

 ```bash
 # Preferred - based on documentation. Copy and paste to bash command line:
 keyring_location=/usr/share/keyrings/ksatechnologies-truenas-proxmox-keyring.gpg
 ```

 ```bash
 # Alternative - If you wish to continue with the old ways.  Copy and paste to bash command line:
 keyring_location=/etc/apt/trusted.gpg.d/ksatechnologies-truenas-proxmox.gpg
 ```

 Copy and paste to bash command line to load the GPG key to the location selected above:
 ```bash
 curl -1sLf 'https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox/gpg.284C106104A8CE6D.key' |  gpg --dearmor >> ${keyring_location}
 ```

 Copy and paste the following code to bash command line to create '/etc/apt/sources.list.d/ksatechnologies-repo.list'
 ```bash
 cat << EOF > /etc/apt/sources.list.d/ksatechnologies-repo.list
 # Source: KSATechnologies
 # Site: https://cloudsmith.io
 # Repository: KSATechnologies / truenas-proxmox
 # Description: TrueNAS plugin for Proxmox VE - Production
 deb [signed-by=${keyring_location}] https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox/deb/debian any-version main

 EOF
 ```

</details>

<details><summary>Step 1.1: For development releases. <i>Disabled</i> by default.</summary>

 ### truenas-proxmox-testing repo - Follows the master branch and you wish to test before a stable release (beta).
 
 Select one of the following GPG Key locations based on your preference.

 ```bash
 # Preferred - based on documentation. Copy and paste to bash command line:
 keyring_location=/usr/share/keyrings/ksatechnologies-truenas-proxmox-testing-keyring.gpg
 ```

 ```bash
 # Alternative - If you wish to continue with the old ways.  Copy and paste to bash command line:
 keyring_location=/etc/apt/trusted.gpg.d/ksatechnologies-truenas-proxmox-testing.gpg
 ```

 Copy and paste to bash command line to load the GPG key to the location selected above:
 ```bash
 curl -1sLf 'https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox-testing/gpg.CACC9EE03F2DFFCC.key' |  gpg --dearmor >> ${keyring_location}
 ```

 Copy and paste the following code to bash command line to create '/etc/apt/sources.list.d/ksatechnologies-testing-repo.list'
 ```bash
 cat << EOF > /etc/apt/sources.list.d/ksatechnologies-testing-repo.list
 # Source: KSATechnologies
 # Site: https://cloudsmith.io
 # Repository: KSATechnologies / truenas-proxmox-testing
 # Description: TrueNAS plugin for Proxmox VE - Testing
 deb [signed-by=${keyring_location}] https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox-testing/deb/debian any-version main

 EOF
 ```

</details>

<details><summary>Step 2.0: Next step after completing any combination of the 1.x steps</summary>

 ### Update apt

 Then issue the following to install the package
 ```bash
 apt update
 apt install truenas-proxmox
 ```

 </details>

 <details><summary>Step 3.0: Maintenance.</summary>

  Then just do your regular upgrade via apt at the command line or the Proxmox Update subsystem; the package will automatically issue all commands to patch the files.
  ```bash
  apt update
  apt [full|dist]-upgrade
  ```

 </details>

</details>

## Uninstall truenas-proxmox

<details><summary>If you wish not to use the package you may remove it at anytime with the following:</summary>

 ```
  apt [remove|purge] truenas-proxmox
 ```

 This will place you back to a normal and non-patched Proxmox VE install.
 
</details>

## Notes:

### Please be aware that this plugin uses the TrueNAS APIs but still uses SSH keys due to the underlying Proxmox VE perl modules that use the ```iscsiadm``` command.

You will still need to configure the SSH connector for listing the ZFS Pools because this is currently being done in a Proxmox module (ZFSPoolPlugin.pm). To configure this please follow the steps at https://pve.proxmox.com/wiki/Storage:_ZFS_over_iSCSI that have to do with SSH between Proxmox VE and TrueNAS. The code segment should start out `mkdir /etc/pve/priv/zfs`.

1. Remember to follow the instructions mentioned above for the SSH keys.

2. Refresh the Proxmox GUI in your browser to load the new Javascript code.

3. Add your new TrueNAS ZFS-over-iSCSI storage using the TrueNAS-API.

4. Thanks for your support.
