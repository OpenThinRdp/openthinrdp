# Domande frequenti

*[English](faq.md)*

## Il progetto

### Che cos'è OpenThinRDP?

Un sistema operativo open source per thin client che si collegano a Windows con Desktop remoto: host di sessione
RDS, raccolte VDI dietro un RD Connection Broker, o qualsiasi PC Windows con Desktop remoto attivo. È Debian 13 con un
kiosk bloccato su FreeRDP, il trasporto UDP di RDP incluso, e un gestore per Windows che governa tutto il parco da una
cartella condivisa.

### È gratuito?

Sì. Licenza Apache 2.0, nessun costo per postazione, nessun abbonamento, nessun account. La ISO e gli aggiornamenti
firmati sono su [GitHub](https://github.com/OpenThinRdp/openthinrdp/releases/latest).

### Non è troppo giovane per usarlo in produzione?

È giovane come progetto pubblico (ottobre 2026), non come sistema. Nasce dal parco di thin client di un'azienda, dove
ha sostituito un sistema operativo commerciale per thin client. Lì lavora ogni giorno su 14 postazioni (scrivanie,
casse, un laboratorio e postazioni di pesatura), e ogni versione arriva a quel parco. In più:

- oltre 170 test di sistema girano a ogni modifica;
- ogni versione viene installata in QEMU/KVM con Secure Boot;
- l'UDP è stato provato per ore con perdita di pacchetti, rete tagliata e client uccisi.

Cosa è in produzione, cosa è solo provato e cosa manca: [status.md](status.md) (in inglese).

### Chi lo mantiene?

Il reparto IT dell'azienda dove gira in produzione, in modo aperto su GitHub. Segnalazioni di errori, prove su altro
hardware e pull request sono benvenute.

## Hardware

### Su quale hardware gira?

Qualsiasi PC o thin client x86 a 64 bit, con UEFI o BIOS tradizionale, 2 GB di RAM e 8 GB di memoria (nessuna per
farlo girare live da una chiavetta USB). Provati: Dell OptiPlex 3000 Thin Client in produzione, QEMU/KVM con UEFI e
con BIOS. Thin client usati come Dell Wyse 5070, HP t630 o Fujitsu Futro S740 rispettano i requisiti. Vedi
[hardware.md](hardware.md) e le guide [sostituire Dell ThinOS](guides/replace-dell-thinos.md) e
[un vecchio PC come thin client](guides/old-pc-thin-client.md) (in inglese).

### Per essere leggero ha tolto i driver?

No. La ISO ha il kernel Debian 13 completo (Linux 6.12) con tutti i driver, e tutti i pacchetti firmware di Debian.
Quello che funziona con Debian 13, o con Ubuntu e Linux Mint dello stesso periodo, funziona anche qui. È leggero
perché non fa girare un desktop.

### Gira su Raspberry Pi o ARM?

In via sperimentale. C'è un'immagine per scheda SD per il Raspberry Pi 4, provata in emulazione ma non ancora su una
scheda vera ([l'immagine](https://github.com/OpenThinRdp/openthinrdp/releases/tag/rpi-test-1),
[cosa controllare](arm.md)). Il Pi 5 non è ancora supportato.

### Gira sui vecchi thin client a 32 bit?

No: Debian 13 non supporta più le CPU solo a 32 bit.

## Desktop remoto

### Usa davvero RDP su UDP?

Sì. FreeRDP non ha il trasporto UDP in nessuna release; OpenThinRDP distribuisce FreeRDP con la pull request che lo
aggiunge ([#13608](https://github.com/FreeRDP/FreeRDP/pull/13608)), che proviamo e su cui riferiamo. Con
`TRANSPORT=auto` la sessione usa UDP, e TCP quando l'UDP è bloccato. Su una linea che perde il 50% dei pacchetti ha
tenuto 19-21 fotogrammi al secondo, dove il TCP era sceso a 0,6 già al 20% ([udp.md](udp.md)).

### A quali Windows si collega?

Host di sessione RDS e raccolte VDI attraverso un RD Connection Broker, oppure un singolo PC o server Windows con
Desktop remoto attivo (Pro, Enterprise, Server), in sede o in Azure, AWS o qualsiasi cloud. Kerberos con NTLM di
riserva, RD Gateway, e la sua VPN WireGuard o OpenVPN per le postazioni fuori sede.

### Funziona con Azure Virtual Desktop o Windows 365?

Non ancora: richiedono l'accesso con Microsoft Entra ID e il gateway di Microsoft, che il kiosk non fa. Un deployment
RDS o macchine virtuali Windows in Azure funzionano, attraverso un RD Gateway o una VPN
([desktop nel cloud](configuration.md#desktops-in-the-cloud)).

### Citrix o VMware/Omnissa Horizon?

No, OpenThinRDP fa solo RDP. Per quelli, vedi [le alternative](alternatives.md).

### Funzionano webcam, cuffie, chiavette USB e smart card?

Sì:

- le webcam attraverso il canale della fotocamera di RDP, e le cuffie attraverso i canali audio di RDP, così Teams,
  Zoom e il browser nella sessione le vedono;
- le chiavette USB arrivano a Windows come unità, oppure come dispositivi interi: chiavette di firma, chiavette del
  tachigrafo e altri dispositivi particolari, anche se inserite durante la sessione;
- i lettori di smart card attraverso il canale delle smart card.

## Gestione

### Serve un server per gestire le postazioni?

No. Le postazioni scrivono il loro stato in una cartella condivisa (SMB) e da lì leggono le impostazioni; un gestore
in PowerShell per Windows mostra tutto il parco, cambia le impostazioni per tutte le postazioni o per una, e apre lo
schermo di qualsiasi postazione nel browser. Niente agenti, niente database, nessun server di gestione
([il gestore](manager.md)).

### Come si fanno gli aggiornamenti? Si può tornare indietro?

Gli aggiornamenti di OpenThinRDP sono pacchetti firmati, da GitHub o dalla vostra cartella. Si installano in
sottofondo e si applicano a fine sessione. Una versione nuova può andare prima a poche postazioni pilota, poi a tutte.
Se qualcosa non va, tutto il parco o una sola postazione tornano alla versione precedente, FreeRDP compreso. Gli
aggiornamenti di sicurezza di Debian si installano da soli.

### È sicuro?

- Gli aggiornamenti sono firmati, e possono essere firmati di nuovo con la sola chiave del vostro sito.
- Niente desktop, niente terminale, niente console di testo.
- SSH solo con chiave, spento di default.
- I segreti della postazione sono sigillati nel TPM quando c'è.
- Le chiavi del parco stanno in una cassaforte con un codice di accesso.

Vedi [security.md](security.md) e [SECURITY.md](../SECURITY.md).

### Si avvia dalla rete (PXE)?

Non ancora. OpenThinRDP gira live da una chiavetta USB oppure si installa, con un'installazione automatica per i
rilasci in serie. L'avvio dalla rete è valutato per una versione futura.

### Supporta 802.1X?

Sì, dalla 0.2.1: 802.1X sul cavo e Wi-Fi WPA2/WPA3-Enterprise, con PEAP (un account di dominio o della macchina) o
EAP-TLS (un certificato della vostra CA). Il server RADIUS viene verificato con la vostra CA prima di mandare
qualsiasi password, e su uno switch senza 802.1X la postazione prosegue da sola. Configurazione con Windows NPS o
FreeRADIUS: [802.1X e Wi-Fi Enterprise](configuration.md#8021x-and-wi-fi-enterprise).

### Perché non semplicemente Linux Mint con Remmina?

Il supporto dell'hardware è lo stesso, ma Remmina non ha RDP su UDP. In più un desktop va bloccato e configurato PC
per PC, e i suoi aggiornamenti arrivano senza postazioni pilota né modo di tornare indietro. Vedi
[le alternative](alternatives.md#linux-mint-ubuntu-or-debian-with-remmina).

### Come lo provo?

Scrivete la ISO su una chiavetta USB e avviate un PC da lì: il sistema live non scrive niente sul disco. Impostate il
broker e il dominio, e accedete ([cinque minuti](../README.it.md#provarlo-in-cinque-minuti)).
