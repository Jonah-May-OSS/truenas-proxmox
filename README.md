# TrueNAS ZFS over iSCSI Plugin for Proxmox VE

Latest release:

[![Latest version of 'truenas-proxmox'](https://api.cloudsmith.com/v1/badges/version/jonah-may-oss/truenas-proxmox/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/?render=true)](https://cloudsmith.io/~jonah-may-oss/repos/truenas-proxmox/packages/detail/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/)


Latest beta:

[![Latest beta version of 'truenas-proxmox'](https://api.cloudsmith.com/v1/badges/version/jonah-may-oss/truenas-proxmox-testing/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/?render=true)](https://cloudsmith.io/~jonah-may-oss/repos/truenas-proxmox-testing/packages/detail/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/)


Latest nightly:

[![Latest nightly version of 'truenas-proxmox'](https://api.cloudsmith.com/v1/badges/version/jonah-may-oss/truenas-proxmox-snapshots/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/?render=true)](https://cloudsmith.io/~jonah-may-oss/repos/truenas-proxmox-snapshots/packages/detail/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/)


## Activity

<details>
 <summary>Expand to see the activity tree</summary>

 <blockquote>

  <details><summary>2025-05-01</summary>

   - Document migrating from freenas-proxmox to truenas-proxmox
   - Apply ZFSPlugin.pm and UI tweaks via sed instead of patch files so they can be universal for versions
   - Remove REST API custom fields for storage since it is no longer used

  </details>
  
  <details><summary>2025-04-28</summary>
  
  - Fork repository to begin update work 
  - Remove donation link from readme
  - Create new Cloudsmith repos to point new code to
  - Cleaned up files and folders to minimize complexity
  - Updated all FreeNAS references to say TrueNAS
  - Configured semi-automated beta builds based off commits to master
  - Rewrite TrueNAS.pm storage plugin to use SSH and webhook CLI tool instead of REST API due to deprecation in 25.04.
  
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

* Port wiki to new fork and build it out
* Tie testing/GA packages to GitHub releases instead of hard-coded versions in packer yaml
  * Update static references in the packer YAML
  * Update static references in the control files
* Fix LBA warnings
  * Fix LBA warnings https://github.com/TheGrandWazoo/freenas-proxmox/issues/203
* Update the documentation - <i>In Progress</i>.
  * Restructure the main README.md for better readability. 
  * Add some screenshots.
* Fix Max Lun Limit issue.
  * https://github.com/TheGrandWazoo/freenas-proxmox/issues/150
* Fix automated builds - <i>In Progress</i>.
  * General Releases
  * Alpha/Nightly Releases
* Autoinstall the SSH keys.
  * Tech spike to see if it is even doable.
* Hashicorp Vault integration.
  * Pull in secrets from a Hashicorp Vault service.  
  * Tech spike to see if it is even doable.

</details>

## New Install Instructions

### Select at least one `Step 1.x` based on your preference. Can be combined.

<details><summary>Step 1.0: For stable releases. <b>Enabled</b> by default.</summary>

 ### truenas-proxmox repo - Currently follows the 3.0 branch.

 Select one of the following GPG Key locations based on your preference.

 ```bash
 # Preferred - based on documentation. Copy and paste to bash command line:
 keyring_location=/usr/share/keyrings/jonah-may-oss-truenas-proxmox-keyring.gpg
 ```

 ```bash
 # Alternative - If you wish to continue with the old ways.  Copy and paste to bash command line:
 keyring_location=/etc/apt/trusted.gpg.d/jonah-may-oss-truenas-proxmox.gpg
 ```

 Copy and paste to bash command line to load the GPG key to the location selected above:
 ```bash
 curl -1sLf 'https://dl.cloudsmith.io/public/jonah-may-oss/truenas-proxmox/gpg.7E6C3EBFF19F8651.key' |  gpg --dearmor >> ${keyring_location}
 ```

 Copy and paste the following code to bash command line to create '/etc/apt/sources.list.d/jonah-may-oss-repo.list'
 ```bash
 cat << EOF > /etc/apt/sources.list.d/jonah-may-oss-repo.list
 # Source: Jonah May OSS
 # Site: https://cloudsmith.io
 # Repository: Jonah May OSS / truenas-proxmox
 # Description: TrueNAS plugin for Proxmox VE - Production
 deb [signed-by=${keyring_location}] https://dl.cloudsmith.io/public/jonah-may-oss/truenas-proxmox/deb/debian any-version main

 EOF
 ```

</details>

<details><summary>Step 1.1: For beta releases. <i>Disabled</i> by default.</summary>

 ### truenas-proxmox-testing repo - Follows the master branch and you wish to test before a stable release (beta).
 
 Select one of the following GPG Key locations based on your preference.

 ```bash
 # Preferred - based on documentation. Copy and paste to bash command line:
 keyring_location=/usr/share/keyrings/jonah-may-oss-truenas-proxmox-testing-keyring.gpg
 ```

 ```bash
 # Alternative - If you wish to continue with the old ways.  Copy and paste to bash command line:
 keyring_location=/etc/apt/trusted.gpg.d/jonah-may-oss-truenas-proxmox-testing.gpg
 ```

 Copy and paste to bash command line to load the GPG key to the location selected above:
 ```bash
 curl -1sLf 'https://dl.cloudsmith.io/public/jonah-may-oss/truenas-proxmox-testing/gpg.02DA93FB91DEBFD9.key' |  gpg --dearmor >> ${keyring_location}
 ```

 Copy and paste the following code to bash command line to create '/etc/apt/sources.list.d/jonah-may-oss-repo.list'
 ```bash
 cat << EOF > /etc/apt/sources.list.d/jonah-may-oss-repo.list
 # Source: Jonah May OSS
 # Site: https://cloudsmith.io
 # Repository: Jonah May OSS / truenas-proxmox-testing
 # Description: TrueNAS plugin for Proxmox VE - Testing
 deb [signed-by=${keyring_location}] https://dl.cloudsmith.io/public/jonah-may-oss/truenas-proxmox-testing/deb/debian any-version main

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

## Migrate from freenas-proxmox

<details><summary>If you are migrating from freenas-proxmox, do the following:</summary>

* Remove freenas-proxmox on each node
```
 apt remove freenas-proxmox
```

* Install truenas-proxmox on each node

* Edit the cluster storage config on a host with
```
 nano /etc/pve/storage.cfg
```

* Find the storage entry, for example
```
 zfs: HDD01
        blocksize 16k
        iscsiprovider freenas
        pool HDD01
        portal 192.168.5.21
        target iqn.2005-10.org.freenas.ctl:proxmox01
        content images
        nowritecache 0
        sparse 0
```

* Change iscsiprovider entry from `freenas` to `truenas`

* Exit out of nano, saving the changes

* Restart the Proxmox services on each host
```
 systemctl restart pve-cluster pvedaemon pveproxy
```
</details>

## Notes:

### Please note this has only been tested with Proxmox 8.4 and TrueNAS SCALE 25.04. The new midclt tool is leveraged, meaning this utility is incompatible with TrueNAS Core and SCALE versions older than 24.10. 24.10 included the utility with experimental support, so while this code may work with it, it is untested and unsupported.

### Please be aware that this plugin uses SSH keys due to the TrueNAS API being deprecated and due to the underlying Proxmox VE perl modules that use the ```iscsiadm``` command.

You will need to configure the SSH connector for listing the ZFS Pools because this is currently being done in a Proxmox module (ZFSPoolPlugin.pm). To configure this please follow the steps at https://pve.proxmox.com/wiki/Storage:_ZFS_over_iSCSI that have to do with SSH between Proxmox VE and TrueNAS. The code segment should start out `mkdir /etc/pve/priv/zfs`.

1. Remember to follow the instructions mentioned above for the SSH keys.

2. Refresh the Proxmox GUI in your browser to load the new Javascript code.

3. Add your new TrueNAS ZFS-over-iSCSI storage using the TrueNAS-API.

4. Thanks for your support.
