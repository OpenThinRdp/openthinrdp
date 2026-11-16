# Guides: how to do it, step by step

Every guide of OpenThinRDP, by what you want to do. Each link opens the page at the right place.

## Start

- **[Getting started](guides/getting-started.md)**: from a USB stick to a managed fleet in seven steps: try it live,
  install it, the Windows side, the management folder, the manager, every new device.
- **[At home](guides/home.md)**: your Windows PC from a laptop or a mini PC in two minutes, from anywhere with
  Tailscale.
- **[Will my computer work?](hardware.md)**: the requirements, the models already running it, firmware settings.

## In the office

- **[For companies](guides/business.md)**: RDS and VDI, zero-touch from the domain, updates you control.
- **[Replacing Dell ThinOS](guides/replace-dell-thinos.md)**: the settings to copy, the firmware, a whole fleet in place.
- **[Proxmox, VMware and Nutanix](guides/proxmox-vmware-thin-client.md)**: Windows VMs on any hypervisor, Linux
  desktops through xrdp.
- **[Used thin clients](guides/used-thin-client.md)** and **[old PCs](guides/old-pc-thin-client.md)**: which ones,
  and how to install them.

## Set it up

Every setting, with its default and what it does: **[every setting](configuration.md)**.

- **[The remote desktop](configuration.md#remote-desktop)**: brokers, collections, a Windows PC, UDP or TCP, monitors.
- **[RD Gateway](configuration.md#rd-gateway)**: the desktops from outside the office.
- **[USB devices and webcams](configuration.md#usb)**: what goes to Windows whole, what as a drive, the camera.
- **[Network and Wi-Fi](configuration.md#network)**: cable, Wi-Fi, several networks, a fixed address.
- **[VPN](configuration.md#vpn)**: WireGuard and OpenVPN.
- **[802.1X and Wi-Fi Enterprise](configuration.md#8021x-and-wi-fi-enterprise)**: with
  [Windows NPS and domain accounts](configuration.md#windows-nps-peap-with-domain-accounts),
  [certificates from AD CS](configuration.md#windows-nps-eap-tls-with-certificates-from-ad-cs) or
  [FreeRADIUS](configuration.md#freeradius).
- **[Desktops in the cloud](configuration.md#desktops-in-the-cloud)**: Azure, AWS and others, through a VPN or an
  RD Gateway.
- **[A screen that shows a web page](configuration.md#web-button-and-kiosk-page)**: a dashboard, a wall screen, a web
  app.
- **[Power schedule](configuration.md#power-schedule)**: on in the morning, off at night, day by day.
- **[Logo, look and language](configuration.md#look-and-language)**.

## Manage the fleet

The management folder, one shared folder that runs every device: **[managing the fleet](management.md)**.

- **[Central settings](management.md#central-settings)**: for every device, a group or one device.
- **[Your logo and background](management.md#logo-and-background-picture)**.
- **[The screen of a device](management.md#remote-screen)**, from your desk.
- **[Signed updates](management.md#signed-updates)**, with **[pilot devices and going back](management.md#pilot-devices-and-going-back)**.
- **[Signed configuration](management.md#signed-configuration)** and **[a fleet on its own key](management.md#a-fleet-on-its-own-key)**.
- **[The vault](management.md#vault)** and **[SSH keys](management.md#ssh-keys)**.

## The manager

- **[The manager](https://openthinrdp.github.io/manager.html)**: a free health center for Hyper-V, Proxmox, vSphere,
  Remote Desktop, SQL, Veeam and certificates, and the fleet in the same window.
- **[The manager, page by page](manager.md)**.
- **[A free health check for Hyper-V and Remote Desktop](guides/hyper-v-rds-health-check.md)**: the manager alone,
  in five minutes.

## Under the hood

- **[RDP over UDP](udp.md)**: how it works, the measurements, how to measure it on your own network.
- **[Every feature](features.md)**, **[security](security.md)**, **[privacy](privacy.md)**,
  **[production readiness](maturity.md)**, **[FAQ](faq.md)**, **[changelog](../CHANGELOG.md)**.
- **[Building your own image](building.md)**, with your logo and settings built in.
