# TrueNAS ZFS over iSCSI Plugin for Proxmox VE

Latest release:

[![Latest version of 'truenas-proxmox'](https://api.cloudsmith.com/v1/badges/version/jonah-may-oss/truenas-proxmox/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/?render=true)](https://cloudsmith.io/~jonah-may-oss/repos/truenas-proxmox/packages/detail/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/)


Latest beta:

[![Latest beta version of 'truenas-proxmox'](https://api.cloudsmith.com/v1/badges/version/jonah-may-oss/truenas-proxmox-testing/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/?render=true)](https://cloudsmith.io/~jonah-may-oss/repos/truenas-proxmox-testing/packages/detail/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/)


Latest nightly:

[![Latest nightly version of 'truenas-proxmox'](https://api.cloudsmith.com/v1/badges/version/jonah-may-oss/truenas-proxmox-snapshots/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/?render=true)](https://cloudsmith.io/~jonah-may-oss/repos/truenas-proxmox-snapshots/packages/detail/deb/truenas-proxmox/latest/a=all;xc=main;d=debian%252Fany-version;t=binary/)

## Useful Links

### [Main Wiki](https://github.com/Jonah-May-OSS/truenas-proxmox/wiki)

### [Activity](https://github.com/Jonah-May-OSS/truenas-proxmox/wiki/Activity)

### [Roadmap](https://github.com/Jonah-May-OSS/truenas-proxmox/wiki/Roadmap)

### [Install Guide](https://github.com/Jonah-May-OSS/truenas-proxmox/wiki/Install-Guide)

### [Uninstall Guide](https://github.com/Jonah-May-OSS/truenas-proxmox/wiki/Uninstall-Guide)

## Notes:

### Please note this has only been tested with Proxmox 8.4 and TrueNAS SCALE 25.04. The new midclt tool is leveraged, meaning this utility is incompatible with TrueNAS Core and SCALE versions older than 24.10. 24.10 included the utility with experimental support, so while this code may work with it, it is untested and unsupported.

### Please be aware that this plugin uses SSH keys due to the TrueNAS API being deprecated and due to the underlying Proxmox VE perl modules that use the ```iscsiadm``` command.

You will need to configure the SSH connector for listing the ZFS Pools because this is currently being done in a Proxmox module (ZFSPoolPlugin.pm). To configure this please follow the steps at https://pve.proxmox.com/wiki/Storage:_ZFS_over_iSCSI that have to do with SSH between Proxmox VE and TrueNAS. The code segment should start out `mkdir /etc/pve/priv/zfs`.

1. Remember to follow the instructions mentioned above for the SSH keys.

2. Refresh the Proxmox GUI in your browser to load the new Javascript code.

3. Add your new TrueNAS ZFS-over-iSCSI storage using the TrueNAS-API.

4. Thanks for your support.
