# BasedFTP

Native macOS-SFTP-Anwendung mit SwiftUI und AppKit, ab macOS 14. Keine Paketabhängigkeiten, Accounts, Werbung oder Telemetrie. Der aktuelle Stand ist eine benutzbare erste Version, keine bereits umfassend gehärtete 1.0.

Die bisherigen Funktionen und Verbesserungen sind im [Changelog](CHANGELOG.md) zusammengefasst.

## Starten und bauen

Voraussetzung: Xcode mit macOS-SDK und Swift 6 oder neuer. Apple Silicon wurde hier getestet; Intel ist als Quellcodeziel vorgesehen, aber nicht auf Hardware geprüft.

- `BasedFTP.xcodeproj` öffnen, Scheme **BasedFTP**, Ziel **My Mac**, Run.
- Alternativ: `bash Scripts/build-app.sh`. Das erzeugt `build/BasedFTP.app` mit lokaler Ad-hoc-Signatur. Die App anschließend im Finder starten.
- `bash Scripts/test.sh` führt Unit- und lokale SFTP-Subsystemtests aus.
- `bash Scripts/integration-test.sh` startet zusätzlich einen temporären SSH-Server **nur auf 127.0.0.1** mit zufälligem Port und eigenen Schlüsseln. Es werden keine System- oder Benutzer-SSH-Einstellungen geändert. Erforderlich: `/usr/sbin/sshd`, `/usr/libexec/sftp-server`, Python 3 und freigegebener Loopback-Netzwerkzugriff. Testdateien und Agent werden am Ende entfernt.

Die Projektdatei wird ohne zusätzliche Tools mit `python3 Scripts/generate-project.py` reproduziert. Swift Package und Xcode verwenden dieselben Quelldateien. Das Build-Skript ist auch eine Alternative, wenn die lokale Xcode-IDE-Installation defekt ist.

## Erste Verbindung

1. Server hinzufügen. Als Host sind DNS-Name, IPv4-Adresse oder ein Alias aus `~/.ssh/config` möglich. Für IPv6 aktuell einen SSH-Alias verwenden. Benutzer und Port dürfen leer bleiben, damit OpenSSH die Konfiguration übernimmt.
2. SSH-Key auswählen oder den vorhandenen SSH-Agent verwenden. Ed25519, RSA mit modernen Signaturen und ECDSA werden durch OpenSSH verarbeitet. Passphrasegeschützte Keys können über den Agent oder die Schlüsselbund-Passphrase entsperrt werden.
3. Für Passwortanmeldung das Passwort eingeben und die Schlüsselbund-Option eingeschaltet lassen. Eingegebene Geheimnisse aktivieren diese Option sichtbar. Zum Löschen eines gespeicherten Geheimnisses das Feld leeren und die Ersetzen-Option einschalten. Bestehende Geheimnisse werden sonst nicht verändert.
4. Bei unbekanntem Host **Host-Key prüfen…** wählen. Alle angebotenen SHA256-Fingerprints unabhängig mit dem Administrator abgleichen und ausdrücklich bestätigen. `ssh-keyscan` allein stellt kein Vertrauen her. Bereits bekannte Schlüssel werden hier niemals ersetzt. Geänderte Schlüssel führen zum Abbruch.
5. Verbindung testen und verbinden. Für eine schnelle Verbindung kann „Serverprofil speichern“ ausgeschaltet werden.

Bei ProxyJump/ProxyCommand die Host-Keys einmal mit dem normalen OpenSSH-Client im Terminal verifizieren. Die anschließenden SFTP-Verbindungen unterstützen diese Konfiguration über OpenSSH. Der Import zeigt explizite Host-Aliase aus der Hauptdatei; Include-Dateien und Wildcards werden beim Import nicht aufgeklappt, bei einer Verbindung jedoch von OpenSSH normal ausgewertet.

## Bedienung

- Gespeicherte Server und zuletzt verwendete Verbindungen öffnen per Einfach- oder Doppelklick. Ein Doppelklick erzeugt genau einen Tab. Die gesamte Lesezeichenzeile ist anklickbar.
- **⌘W** schließt den aktiven Verbindungstab; nach dem letzten Tab bleibt das Fenster mit der Startansicht offen. **⇧⌘W** schließt das ganze Fenster.

- Zwei unabhängig navigierbare Dateipanels mit verschiebbarem Divider, Pfadeingabe, Breadcrumbs, Zurück/Vorwärts und Doppelklick. Beide Panels verwenden eine native NSOutlineView-Baumansicht: Ordner über den Pfeil aufklappen, Unterordner werden asynchron nachgeladen. Rechte/Linke Pfeiltaste klappt die Auswahl auf/zu. Beim Aktualisieren bleiben offene Zweige erhalten.
- Mehrfachauswahl über die nativen Tabellen. Name, Größe, Typ, Änderungszeit und oktale Rechte sind sichtbar. Sortierfeld und Richtung über die Spaltenköpfe oder im Panel-Menü wählen. Ein Suchfeld filtert das aktuelle Verzeichnis lokal nach Dateinamen.
- Upload/Download über Panel-Button, Toolbar, Kontextmenü, **⌘T** oder **F5**. Dateien und Ordner zwischen den Panels ziehen. Auf einen Zielordner fallenlassen, um direkt dort hoch-/herunterzuladen. Innerhalb desselben Panels bedeutet Drag & Drop **Verschieben**: auf Ordnerzeilen (auch eingeklappte), Breadcrumbs oder die freie Fläche für das aktuelle Verzeichnis. Bestehende Ziele werden beim Verschieben nicht überschrieben; Selbst-/Unterordner-Ziele werden abgelehnt. Mehrfach ausgewählte Ordner und ihre Kinder werden gemeinsam nur einmal verschoben. Aus dem Finder sind Uploads in das Remote-Panel möglich. Export per Drag & Drop aus dem Remote-Panel in den Finder ist noch nicht implementiert.
- **⌘R** aktualisiert das aktive Panel, **⌘↑** öffnet das Elternverzeichnis, **⌘[ / ⌘]** navigiert zurück/vorwärts, **⇧⌘.** blendet versteckte Dateien ein/aus, **⇧⌘N** erstellt Ordner, **⌘Return** benennt die Auswahl um, **⌘⌫** öffnet die Löschbestätigung. Das aktive Panel wird durch Auswahl/Klick bestimmt.
- Kontextmenüs für neue Dateien/Ordner, Umbenennen, Verschieben in einen absoluten Zielordner, chmod und Löschen. Lokal wird der Papierkorb benutzt; Remote-Löschen ist nach Bestätigung endgültig und rekursiv.
- Die Transferansicht konfiguriert 1–8 parallele Jobs und die Konfliktstrategie für **neu hinzugefügte** Jobs. Standard: Umbenennen. Überschreiben, Überspringen und explizites Fortsetzen stehen zur Verfügung.
- Pause hält den jeweiligen lokalen SSH-Prozess an; Fortsetzen setzt ihn fort. Sehr lange Pausen können serverseitige Timeouts verursachen. Abbrechen beendet diesen Prozess. Erneut startet einen neuen Job mit derselben Strategie. Fortsetzen am fehlgeschlagenen/abgebrochenen Job verwendet dessen erhaltene Arbeitsdateien und merkt sich bereits abgeschlossene Dateien, solange die App geöffnet bleibt.
- Remote-Datei öffnen: Arbeitskopie herunterladen, im macOS-Standardeditor bearbeiten, dort speichern und im geöffneten Bearbeitungsdialog ausdrücklich hochladen. Änderungen auf dem Server werden anhand Größe und Änderungszeit erkannt. Bei Konflikten bleibt die lokale Kopie erhalten.

## Architektur und technische Entscheidungen

- `Models.swift`: Profile, Dateimetadaten, Navigation und Konfliktstrategien.
- `SFTP.swift`: Binäres SFTP-v3-Framing und Dateibefehle über stdin/stdout von `/usr/bin/ssh -s … sftp`. Keine Shell-Befehlsketten, kein Parsen von `ls`, keine selbst implementierte SSH-Kryptografie.
- `FileSystem.swift`: Lokale Dateizugriffe und asynchrone Panel-ViewModels mit Schutz gegen veraltete Navigationsergebnisse.
- `Transfers.swift`: Begrenzte parallele Queue, rekursive Übertragung, Konflikte, Fortschritt, durchschnittliche Geschwindigkeit und geschätzte Restzeit.
- `Security.swift`: macOS Keychain und geheimnisfreie JSON-Profile in `~/Library/Application Support/BasedFTP/profiles.json`.
- `FileOutlineView.swift`: Native AppKit-Baumansicht mit Auswahl, Drag-Quellen, zeilenbezogenen Drop-Zielen, Spaltensortierung und Kontextmenüs.
- `Workspace.swift`, `FilePane.swift`, `ProfileEditor.swift`, `RemoteEdit.swift`: SwiftUI-Ansichten und Verbindungszustand.

**SSH-Backend:** Statt eine zusätzliche SSH-Bibliothek zu bündeln, verwendet die App das von Apple ausgelieferte, gepflegte OpenSSH. Das erfüllt den Zweck einer etablierten SSH-Implementierung ohne externe Abhängigkeit und erhält die Kompatibilität mit Agent, `Include`, `Match`, IdentityFile und ProxyJump. Die App implementiert nur SFTP-v3-Dateibefehle, nicht die Transportverschlüsselung. Das ebenfalls geprüfte [libssh2](https://github.com/libssh2/libssh2) wäre eine zusätzliche C-Build-/Distributionsabhängigkeit. [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) beschreibt sich als SSH-Baustein statt fertigem Client und nennt in seinem dokumentierten asymmetrischen Algorithmensatz Ed25519/ECDSA; für die geforderte Kombination mit RSA und bestehender OpenSSH-Konfiguration fiel die Entscheidung auf den Systemclient.

Jede Navigation, Dateioperation bzw. jeder Transferjob verwendet einen eigenen SSH-Subsystemprozess. Dadurch beeinträchtigt der Abbruch eines Jobs andere Verbindungen nicht. Es gibt derzeit keinen dauerhaft von der App verwalteten Verbindungspool und keine automatische Wiederholung schreibender Operationen. „Erneut versuchen“ verbindet neu. Benutzerseitig konfigurierte OpenSSH-Multiplexing-Einstellungen können weiterhin wirken.

Die Protokoll-I/O läuft außerhalb des Main Actors. Die Oberfläche erhält gedrosselte Fortschrittsupdates. Transfers verwenden 64-KiB-Blöcke mit bis zu acht gleichzeitig ausstehenden Anfragen. Antwort-IDs werden geprüft, anders geordnete Antworten gepuffert und kurze Server-Leseantworten vervollständigt. Ein verbindungsübergreifender Bandbreitenregler und adaptive Fenstergrößen fehlen derzeit.

Referenzen, geprüft bei der Implementierung:

- [OpenSSH SFTP-Client und Fähigkeiten](https://man.openbsd.org/sftp)
- [OpenSSH-Konfiguration und Prioritäten](https://man.openbsd.org/ssh_config)
- [SFTP-v3-Protokoll](https://www.ietf.org/archive/id/draft-ietf-secsh-filexfer-02.txt)
- [OpenSSH-SFTP-Erweiterungen](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL)

## Sicherheit und Grenzen

- `StrictHostKeyChecking=yes`, keine Agent-Weiterleitung, keine LocalCommand-Ausführung, keine Weiterleitungen. Die App erzwingt `~/.ssh/known_hosts` und `/etc/ssh/ssh_known_hosts`; alternative KnownHosts-Pfade aus der SSH-Konfiguration werden absichtlich nicht übernommen. DNS-basierte automatische Host-Key-Annahme und automatische Schlüsselupdates sind deaktiviert.
- Passwörter und Passphrasen befinden sich nur im macOS-Schlüsselbund. Der eigene kurzlebige ASKPASS-Unterprozess liefert sie über eine Pipe an OpenSSH. Es gibt keine Geheimnisse in Prozessargumenten, Umgebungsvariablen, Profil-JSON oder Logs. Private Schlüssel bleiben an ihrem bestehenden Ort.
- Profil- und Dateinamen werden nicht als Shellcode ausgeführt. Hostnamen und Ports werden validiert, Protokollpakete haben Größenlimits. UTF-8-Dateinamen einschließlich Leerzeichen, Anführungszeichen, Unicode und Zeilenumbrüchen sind unterstützt. Nicht-UTF-8-Dateinamen werden ausdrücklich abgelehnt.
- Neue Transfers schreiben zunächst eine eindeutig benannte `.partial`-Datei im Zielordner. Erst nach erfolgreichem Abschluss wird sie übernommen. OpenSSH-Server verwenden dafür `posix-rename@openssh.com`; bei Servern ohne diese Erweiterung ist Überschreiben nach abgeschlossenem Upload nicht atomar. Nach Fehlern können solche versteckten Arbeitsdateien zur manuellen Bereinigung zurückbleiben.
- **Fortsetzen** schreibt direkt in die bestehende Zieldatei. Nur bei identischem Präfix verwenden: SFTP-v3 garantiert keinen Inhaltsvergleich vorhandener Teilstücke. Bei größerer Zieldatei wird abgebrochen. „Erneut“ übernimmt die ursprüngliche Strategie. Der Button „Fortsetzen“ am abgebrochenen Job verwendet dessen gespeicherte Arbeitsdateipfade; nach einem App-Neustart müssen zurückgebliebene Arbeitsdateien manuell zugeordnet/umbenannt werden. Vorher sicherstellen, dass die Quelle unverändert ist.
- Symlinks und Spezialdateien werden bei Transfers ausdrücklich abgelehnt, damit rekursive Übertragungen keine Links verfolgen. Navigation zu einem bekannten Zielpfad bleibt möglich. Es gibt keine vollständige Absicherung gegen gleichzeitige böswillige Änderungen des Dateisystems.
- Remote-Bearbeiten verwendet derzeit keinen atomaren Versionsvergleich und lädt direkt über die bestehende Datei. Gleichzeitige Änderungen mit identischer Größe/sekundengenauem Zeitstempel können unerkannt bleiben. Arbeitskopien bleiben in einem privaten temporären Unterordner und werden nicht automatisch gelöscht.
- Queue und offene Tabs überleben einen App-Neustart noch nicht. Es gibt keine Verzeichnissynchronisierung, keinen Verzeichnisvergleich und keine Bandbreitenbegrenzung. Ein eigener Editor-Picker und automatisch überwachte Editor-Uploads fehlen. Diese Funktionen werden nicht als fertig dargestellt.
- Die App ist für lokalen Build und direkte Nutzung gedacht, derzeit ohne App-Sandbox, Distribution-Signatur und Notarisierung. Keine App-Store-Freigabe. Zugriff auf macOS-geschützte Ordner unterliegt den normalen Systemrechten.

## Verifikation dieses Stands

Details und tatsächlich ausgeführte Prüfungen stehen in `VALIDATION.md`. Passwortanmeldung und die Keychain-ASKPASS-Kette benötigen zusätzlich einen interaktiven Test mit einem entsprechenden Testkonto; sie sind implementiert, aber nicht als vollständig end-to-end getestet ausgewiesen. Große produktive Verzeichnisse, stundenlange Transfers, unterschiedliche Drittanbieter-Server und ältere macOS-Versionen benötigen weitere Praxistests, bevor man diesen Stand als professionell gehärtete 1.0 einstuft.
