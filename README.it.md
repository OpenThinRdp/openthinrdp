<p align="center"><img src="docs/logo.png" alt="OpenThinRDP" width="480"></p>

<p align="center"><b>Sistema operativo per thin client gratuito e open source, con l'RDP su UDP,<br>
per Desktop remoto Windows, RDS e VDI. E un gestore Windows gratuito per l'infrastruttura e la flotta.</b></p>

<p align="center">
<a href="https://github.com/OpenThinRdp/openthinrdp/releases/latest"><b>Scarica l'ultima versione</b></a>
&nbsp;·&nbsp; <a href="https://openthinrdp.github.io/">Sito</a>
&nbsp;·&nbsp; <a href="https://openthinrdp.github.io/manager.html">Il gestore</a>
&nbsp;·&nbsp; <a href="README.md">English</a>
</p>

Questa pagina riassume il progetto in italiano. La documentazione completa e aggiornata è in inglese: i link qui sotto
portano lì.

## OpenThinRDP: il thin client

OpenThinRDP trasforma piccoli PC e vecchi thin client in postazioni che si accendono direttamente sul modulo di accesso
e si collegano a Windows: al desktop o alla VM dell'utente tramite un RD Connection Broker, a un host di sessione o a
qualsiasi PC con Desktop remoto, in sede o nel cloud.

- **RDP su UDP**: FreeRDP con il trasporto UDP, che regge le linee che perdono pacchetti dove il solo TCP rallenta.
  [I numeri misurati](docs/udp.md).
- **Debian 13**, si installa sulla postazione o gira live da una chiavetta USB. Hyper-V, Proxmox, VMware o cloud: va
  bene qualsiasi infrastruttura con Desktop remoto Windows.
- **Gestione da una cartella condivisa**: configurazione centrale, aggiornamenti firmati, logo, lo schermo di ogni
  postazione nel browser. Nessun agente, nessun server di gestione, nessuna licenza per postazione.
- **Configurazione automatica dal dominio** (zero-touch), webcam, USB, VPN, 802.1X, RD Gateway.
- Licenza GPLv3. Alternativa gratuita a IGEL OS e Dell ThinOS: [il confronto](docs/alternatives.md).

Per iniziare: [Getting started](docs/guides/getting-started.md) · [Hardware provato](docs/hardware.md) ·
[FAQ](docs/faq.md) · [Novità di ogni versione](CHANGELOG.md).

## OpenThinRDP Manager: il gestore

Il gestore **non è uno script PowerShell per modificare i file .conf**: è un programma Windows gratuito, con
l'interfaccia in italiano e in inglese, che non si installa. Fa due cose in una finestra:

- **Centro salute dell'infrastruttura Windows**, anche senza nessun thin client OpenThinRDP: host e cluster di failover
  Hyper-V, Servizi Desktop remoto, controller di dominio e DNS, SQL Server AlwaysOn, backup delle VM, Dell iDRAC,
  Proxmox, vSphere, Veeam, Citrix e certificati. Trova cosa non va, lo dice in una frase e lo ripara quando confermi.
  Nessun agente, nessun server, nessun database.
- **Gestione della flotta OpenThinRDP**: stato di ogni postazione, impostazioni centrali, gruppi, aggiornamenti,
  sessioni e desktop, schermo remoto.

Si aggiorna da solo dalle release firmate. Pagina del gestore: [openthinrdp.github.io/manager.html](https://openthinrdp.github.io/manager.html) ·
progetto: [OpenThinRdp/openthinrdp-manager](https://github.com/OpenThinRdp/openthinrdp-manager) ·
guida: [docs/manager.md](docs/manager.md) ·
[controllo di salute per Hyper-V e Desktop remoto](docs/guides/hyper-v-rds-health-check.md).

## Domande rapide

**OpenThinRDP è gratuito?** Sì: il sistema dei thin client è open source (GPLv3), il gestore è gratuito anche per uso
commerciale.

**Serve un server di gestione?** No: basta una cartella condivisa di Windows; il gestore lavora su quella.

**Il gestore funziona senza thin client OpenThinRDP?** Sì: il centro salute controlla Hyper-V, Desktop remoto, dominio,
SQL, backup e hardware anche da solo.

**Dove segnalo un problema?** Nelle [issue di GitHub](https://github.com/OpenThinRdp/openthinrdp/issues), in italiano o in
inglese.
