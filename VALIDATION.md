# Verifikation

Stand: 7. November 2026.

## Tatsächlich ausgeführt

Umgebung: Apple Silicon, macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2. Deployment-Target des Projekts: macOS 14.

| Prüfung | Ergebnis |
| --- | --- |
| Swift-Package-Debug-Build | Erfolgreich |
| Optimierter Release-Build via `Scripts/build-app.sh` | Erfolgreich |
| Start von `build/BasedFTP.app` über macOS | Erfolgreich; finalen Release-Build erneut gestartet |
| App-Bundle-Plist und Ad-hoc-Signatur | `plutil` und `codesign --verify --deep --strict` erfolgreich |
| Xcode-Projektdatei und Scheme-XML | Syntaxprüfung erfolgreich |
| Komplette Testsuite mit isoliertem SSH-Server | 12 Tests, 0 Fehler, keine übersprungenen Tests |
| Zusätzlicher SSH-Rundlauf mit RSA-3072 | Erfolgreich |
| Zusätzlicher SSH-Rundlauf mit ECDSA-P256 | Erfolgreich |
| Zusätzlicher SSH-Rundlauf mit verschlüsseltem Ed25519-Key über eigenen Agent | Erfolgreich |

Das Integrationsskript führte damit insgesamt 15 erfolgreiche Testausführungen aus: zwölf unterschiedliche Testmethoden und drei weitere Schlüsselvarianten desselben SSH-Rundlauftests. Ohne gestarteten SSH-Testserver überspringt `Scripts/test.sh` zwei ausdrücklich gekennzeichnete SSH-Integrationstests.

## Inhalt der automatisierten Prüfungen

- Binäres Framing, Integer-Endianness, UTF-8 und abgeschnittene/überlange Paketfelder.
- Navigationsverlauf mit Zurück/Vorwärts und Verzweigung.
- Validierung von Host, Port und Dateinamen, sicherheitsrelevante SSH-Argumente.
- Reales lokales `/usr/libexec/sftp-server`: Listing, stat, Upload, Download, beide Fortsetzungsrichtungen, chmod, mkdir, exklusives Erstellen, rename und rekursives Löschen.
- Bytegenauer Rundlauf einer 2,8-MB-Datei, einschließlich Unicode, Leerzeichen, Anführungszeichen, Glob-Zeichen und Zeilenumbruch im Namen.
- Rekursive Uploads/Downloads, Konfliktstrategien und ausdrückliche Ablehnung von Symlinks.
- Absichtlich abgebrochener Upload in eine Arbeitsdatei: bestehendes Ziel bleibt unverändert; Fortsetzen übernimmt die Arbeitsdatei korrekt. Ein vor Dateibeginn fehlgeschlagener Job respektiert beim Fortsetzen weiterhin seine ursprüngliche Umbenennen-Strategie.
- Protokoll-Testfixture für anders geordnete Antworten und kurze Leseantworten bei mehreren ausstehenden Anfragen. Diese Fixture wird ausschließlich in Tests verwendet.
- Echtes SSH auf Loopback mit separat generiertem Host-Key und Client-Key, isolierter `known_hosts`, Listing und Datei-Rundlauf.
- Unbekannte und absichtlich geänderte Host-Keys führen tatsächlich zum Verbindungsabbruch.

## Visuelle Prüfung

Die App wurde über die native macOS-Oberfläche gestartet und bedient:

- Startansicht und Verbindungsdialog geöffnet und geschlossen.
- Ungespeicherte Testverbindung zu einem geschlossenen Loopback-Port angelegt; keine neuen Benutzerprofile oder Zugangsdaten gespeichert.
- Beide Panels, Transferansicht und die verständliche SSH-Fehleranzeige kontrolliert.
- Lokales Verzeichnis über die Pfadeingabe in das Projektverzeichnis gewechselt; reale Dateieinträge wurden angezeigt.
- Den temporären Verbindungstab geschlossen und den finalen Release-Build neu gestartet.

Kein vollständiger automatisierter UI-Regressionstest: insbesondere panelübergreifende Upload-/Download-Drags, alle Tastaturkombinationen, paralleles Queue-Verhalten, lange Pausen, Light Mode und die Editor-Rückübertragung wurden noch nicht interaktiv vollständig durchgespielt.

## Einschränkung der lokalen Xcode-Installation

`xcodebuild -project BasedFTP.xcodeproj -scheme BasedFTP -configuration Debug -derivedDataPath .build/Xcode CODE_SIGNING_ALLOWED=NO build` wurde versucht. Der Prozess bricht vor dem Projektbuild ab, weil das installierte `IDESimulatorFoundation`-Plugin ein nicht vorhandenes Symbol aus `/Library/Developer/PrivateFrameworks/DVTDownloads.framework` erwartet:

```
Symbol not found: _$s12DVTDownloads21DownloadableAssetTypeO22downloadableDependencyyAcA0bF4InfoVcACmFWC
```

Die Systeminstallation wurde nicht verändert. Das Xcode-Projekt einschließlich XCTest-Target ist vorhanden und syntaktisch geprüft; sein Build und Test-Run in dieser IDE konnten wegen dieses lokalen Toolchain-Problems nicht bestätigt werden. Derselbe App-Quellcode kompiliert mit SwiftPM; daraus wurde ein signiertes, tatsächlich gestartetes `.app`-Bundle erzeugt.

## Noch nicht verifiziert

- Passwortauthentifizierung und direkter Zugriff des ASKPASS-Unterprozesses auf den macOS-Schlüsselbund mit einem interaktiven Testkonto.
- Direkte Keychain-Passphrase-Authentifizierung ohne Agent; verschlüsselte Keys über einen Agent sind getestet.
- Host-Key-Einrichtung über den Fingerprint-Dialog gegen einen externen Server, ProxyJump und komplexe SSH-Konfigurationen.
- Server ohne OpenSSH-Erweiterungen, unterschiedliche SFTP-Anbieter, nicht unterstützte Protokollversionen außerhalb v3.
- Intel-Hardware, macOS 14–26, sehr große Verzeichnisse und stundenlange Transfers.
- Notarisierung und Distribution; nur lokale Ad-hoc-Signatur vorhanden.

Die funktionalen Grenzen und Sicherheitsentscheidungen sind im README dokumentiert. Dieser Stand ist kein Nachweis einer externen Sicherheitsprüfung oder einer umfassend produktionsgehärteten Version 1.0.

## Ergänzung: native Baumansicht und Drag & Drop

- Beide Dateipanels verwenden jetzt NSOutlineView mit nativen Aufklapppfeilen und Tastaturnavigation. Unterordner werden asynchron geladen; beim Aktualisieren werden offene Zweige wiederhergestellt.
- Zwei zusätzliche ViewModel-Tests prüfen verschachteltes Aufklappen, Filter mit erhaltenen Vorfahren, Aktualisieren, Umbenennen innerhalb eines Unterordners, doppelte Drag-Payloads/überlappende Mehrfachauswahl, tatsächliches Verschieben sowie Konflikt- und Selbstverschiebeschutz einschließlich eines Symlink-Zielalias.
- Der reale lokale SFTP-Subsystemtest prüft zusätzlich das Verschieben eines Ordners mitsamt einer enthaltenen Datei.
- In einer getrennten Vorschau-App wurde eine echte Testdatei im aufgeklappten Baum von `Quelle/Unterordner/beispiel.txt` per Maus auf `Ziel` gezogen. Die native Outline zeigte die Datei danach als Kind von `Ziel`; die Prüfung des Dateisystems bestätigte `Ziel/beispiel.txt` und die Entfernung am Ausgangspfad.
- Die dabei entdeckte Fehlleitung von zellbasierten SwiftUI-Drops in das Stammverzeichnis wurde durch native NSOutlineView-Drop-Delegates ersetzt. Ordnerzeilen werden als vollständige Ziele behandelt; interne Verschiebeoperationen liefern `.move`, panelübergreifende Transfers `.copy`.
- Release-Build, Signaturprüfung und aktualisierte Xcode-Projektdatei erfolgreich. Die abschließende SSH-Integrationsrunde absolvierte alle zwölf Testmethoden sowie drei weitere Schlüsselvarianten ohne Fehler.
- Die Vorschau wurde nach dem Test beendet. Die bereits laufende Haupt-App muss zum Laden dieses Builds einmal beendet und neu geöffnet werden.

## Ergänzung: Lesezeichen und Tab-Tastenkürzel

- Einfach- und Doppelklick auf gespeicherte Server und zuletzt verwendete Verbindungen nutzen denselben Aktivierungsweg. Aktivierungen desselben Profils innerhalb des macOS-Doppelklickintervalls werden zusammengefasst, sodass ein Doppelklick genau einen Tab erzeugt.
- Der Standard-Menübefehl zum Schließen wurde durch „Tab schließen“ (⌘W) und „Fenster schließen“ (⇧⌘W) ersetzt. Der letzte geschlossene Tab führt zur Startansicht im weiterhin geöffneten Fenster. Beim Schließen wird der benachbarte Tab ausgewählt.
- Zwei zusätzliche Unit-Tests für die Doppelklick-Zusammenfassung und das Schließen aktiver bzw. inaktiver Tabs bestehen. Die lokale Testsuite absolvierte 14 Testmethoden: 12 bestanden, die zwei separat konfigurierten SSH-Integrationstests wurden in dieser Runde übersprungen.
- In einer separaten Vorschau-App wurde ein vorhandenes Lesezeichen mit einem echten Doppelklick geöffnet: genau ein Tab. Anschließend schloss ⌘W diesen Tab; die Startansicht und das Fenster blieben sichtbar. Die Erreichbarkeit des Servers war für diese UI-Prüfung nicht erforderlich.
- Release-App erfolgreich neu gebaut.
