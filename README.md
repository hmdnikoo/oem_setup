# oem_setup

Prepare an Ubuntu Desktop install for delivery to an end user, OEM style.

Run it while logged in as the temporary `oem` user:

```bash
sudo bash oem-prepare.sh
```

What it does:

1. Fully updates the system (apt, snap, flatpak).
2. Installs and enables `gnome-initial-setup` (the Welcome wizard) and removes auto-login from GDM.
3. Installs a one-shot boot service. On the next boot, before the login screen appears, it deletes the `oem` user and then removes itself.
4. The Welcome screen then asks the customer to create their own account.

## Options

| Option | Description |
|---|---|
| `--user NAME` | Temporary user to remove (default: `oem`) |
| `--clone` | Reset machine-id and SSH host keys (clone the disk **before** first boot) |
| `--no-reboot` | Don't offer to reboot at the end |
| `--version` | Print script version |

The log of the first-boot step is in `/var/log/oem-finalize.log`.

## Download a specific version

```bash
wget https://raw.githubusercontent.com/hmdnikoo/oem_setup/v1.0.0/oem-prepare.sh
```

Every version is listed under [Releases / Tags](https://github.com/hmdnikoo/oem_setup/tags).
