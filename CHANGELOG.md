# Changelog

Alle bisher umgesetzten Funktionen und Verbesserungen von BasedFTP. Der initiale Commit fasst die bisherigen Entwicklungsschritte zusammen; sie werden nicht nachträglich als separate Commits dargestellt.

## [0.1.0] – 2026-11-07

Erster lokal startbarer Entwicklungsstand für macOS 14 und neuer. Noch keine notarisiert veröffentlichte oder umfassend produktionsgehärtete Version.

### Hinzugefügt

#### Native Anwendung und Projekt

- Native SwiftUI-Anwendung mit AppKit, modularen ViewModels und asynchroner Datei-I/O.
- Xcode-Projekt mit gemeinsamem Scheme und XCTest-Target sowie ein Swift Package für dieselben Quellen.
- Unterstützung für systemgesteuerten Dark und Light Mode, SF Symbols, Toolbar, Sidebar und Statusleiste.
- Eigenes App-Icon mit reproduzierbarer AppKit-Zeichenvorlage und Icon-Ressourcen.
- Skripte zum Erzeugen des Xcode-Projekts, Bauen eines lokal signierten App-Bundles und Ausführen der Tests.
- README mit Build-Anleitung, Bedienung, Architekturentscheidungen und bekannten Einschränkungen sowie separater Verifikationsbericht.
- Lokales Git-Repository, initialer Commit und dieser Changelog.

#### Dateibrowser und Navigation

- Zwei unabhängig navigierbare Panels für lokale und entfernte Dateien mit verschiebbarem Divider.
- Pfadeingabe, Breadcrumbs, Elternverzeichnis, Zurück/Vorwärts und Öffnen per Doppelklick.
- Native NSOutlineView-Baumansicht in beiden Panels mit aufklappbaren Ordnern und mehreren Hierarchieebenen.
- Asynchrones Nachladen von Unterordnern; Wiederherstellung offener Zweige beim Aktualisieren.
- Native Mehrfachauswahl und Pfeiltastenbedienung für die Baumstruktur.
- Anzeige von Name, Größe, Typ, Änderungsdatum und oktalen Dateirechten.
- Sortierung über Spaltenköpfe und Panel-Menü, aufsteigende/absteigende Reihenfolge.
- Anzeige versteckter Dateien und Filterung nach Dateinamen; passende geladene Kinder bleiben mit ihren Vorfahren sichtbar.
- Kontextmenüs und Tastaturkürzel für typische Dateioperationen.

#### SSH, SFTP und Sicherheit

- SSH-Transport über das mit macOS ausgelieferte OpenSSH, ohne externe Paketabhängigkeiten oder eigene SSH-Kryptografie.
- Binärer SFTP-v3-Client mit Antwort-ID-Prüfung und begrenzten Paketgrößen, ohne Parsen von Terminal-Dateilistings.
- Verzeichnislisting, Pfadauflösung, Dateimetadaten, Lesen, Schreiben, Erstellen, Umbenennen, Löschen und chmod.
- Passwort- und SSH-Key-Authentifizierung über OpenSSH; Unterstützung für Ed25519, RSA, ECDSA und SSH-Agent.
- Schlüsselbund-Anbindung für Passwörter und Key-Passphrasen über einen kurzlebigen ASKPASS-Unterprozess.
- Verwendung bestehender SSH-Konfigurationen, individueller Ports und privater Schlüssel an ihrem vorhandenen Speicherort.
- Strikte Host-Key-Verifikation mit `known_hosts`; keine automatische Annahme unbekannter oder geänderter Schlüssel.
- Dialog zum Abgleich von SHA256-Fingerprints und ausdrücklich bestätigten Hinzufügen neuer Host-Keys.
- Verbindungs- und Inaktivitätszeitlimits, SSH-Keepalives, aussagekräftige Fehlermeldungen und erneutes Verbinden.
- Validierung von Host, Port und Dateinamen; Unterstützung von UTF-8-Dateinamen einschließlich Leerzeichen, Anführungszeichen und Zeilenumbrüchen.
- Keine Telemetrie, Werbung, Accounts oder kostenpflichtigen Dienste.

#### Transfers und Dateioperationen

- Upload und Download einzelner Dateien sowie rekursiver Ordnerstrukturen.
- Warteschlange mit konfigurierbarer Begrenzung auf 1–8 parallele Jobs.
- Fortschritt, durchschnittliche Geschwindigkeit, geschätzte Restzeit und Status pro Job.
- Pause, Weiterlaufen, Abbrechen, erneuter Versuch und explizites Fortsetzen unterbrochener Transfers.
- Konfliktstrategien Überspringen, Umbenennen, Überschreiben und Fortsetzen; Umbenennen als Standard.
- 64-KiB-Blöcke mit bis zu acht gleichzeitig ausstehenden Anfragen; Behandlung vertauschter Antworten und kurzer Leseantworten.
- Übertragung in eindeutig benannte Arbeitsdateien vor Übernahme am endgültigen Ziel; Unterstützung von OpenSSH-POSIX-Rename.
- Fortsetzungsinformationen während der laufenden App-Sitzung für Arbeitsdateien und bereits abgeschlossene Dateien.
- Dateien und Ordner erstellen, umbenennen, verschieben und löschen sowie Dateirechte ändern.
- Lokales Löschen über den Papierkorb; bestätigtes, endgültiges rekursives Löschen auf dem Server.
- Remote-Dateien temporär herunterladen, im zugeordneten macOS-Editor öffnen und ausdrücklich wieder hochladen; Konfliktprüfung anhand Größe und Änderungszeit.

#### Drag & Drop

- Upload und Download zwischen den Panels, auch direkt in einen Zielordner.
- Tatsächliches Verschieben innerhalb des lokalen beziehungsweise entfernten Panels.
- Native Drop-Ziele auf vollständigen Ordnerzeilen, Breadcrumbs und der freien Verzeichnisfläche.
- Native Hervorhebung des Drop-Ziels und Unterscheidung zwischen Verschieben und Übertragen.
- Mehrfachauswahl mit Zusammenfassung doppelter Drag-Payloads und überlappender Eltern-/Kind-Auswahlen.
- Prüfung vorhandener Ziele vor dem Verschieben; kein stillschweigendes Überschreiben.
- Schutz gegen Verschieben eines Ordners in sich selbst oder einen Unterordner, einschließlich kanonischer Pfadauflösung.
- Uploads aus dem Finder in das Remote-Panel.

#### Verbindungen und Lesezeichen

- Gespeicherte Serverprofile, Favoriten und zuletzt verwendete Verbindungen.
- Mehrere gleichzeitige Verbindungen in Tabs und ungespeicherte Schnellverbindungen.
- Verbindungstest und Import expliziter SSH-Host-Aliase aus der Hauptkonfigurationsdatei.
- Öffnen von Lesezeichen per Einfach- und Doppelklick; ein Doppelklick erzeugt genau einen Tab.
- Anklickbare gesamte Lesezeichenzeilen.
- ⌘W schließt den aktiven Verbindungstab; nach dem letzten Tab bleibt die Startansicht im Fenster erhalten.
- ⇧⌘W schließt das ganze Fenster; nach dem Schließen eines Tabs wird der benachbarte Tab ausgewählt.

#### Tests

- Unit-Tests für Paketframing, Navigation, Eingabevalidierung, Lesezeichen-Aktivierung und Tab-Schließen.
- Tests gegen den realen lokalen OpenSSH-SFTP-Subsystemserver für Dateioperationen, rekursive Transfers, Konflikte, Abbruch und Fortsetzen.
- Protokoll-Testfixture für vertauschte Antworten und kurze Leseantworten, ausschließlich für Tests.
- Tests der Baumansicht-ViewModels für Aufklappen, Filter, Aktualisierung, verschachteltes Umbenennen und sichere Verschiebeoperationen.
- Isolierter Loopback-SSH-Testserver mit eigenen temporären Schlüsseln und eigener `known_hosts`.
- SSH-Integrationstests für Ed25519, RSA, ECDSA, einen verschlüsselten Key über einen separaten Agent sowie Ablehnung unbekannter und geänderter Host-Keys.

### Behoben und verbessert

- Zellbasierte SwiftUI-Drops durch native NSOutlineView-Drop-Delegates ersetzt, damit Drops zuverlässig im Zielordner ankommen.
- Umbenennen aufgeklappter Untereinträge verwendet deren tatsächliches Elternverzeichnis.
- Dateinavigation berücksichtigt kanonische lokale Pfade; Baum-Einrückung folgt der geladenen Hierarchie.
- Schutz vor veralteten Navigationsergebnissen sowie Abbruch laufender SSH-Operationen und Aufräumen beim Beenden.
- Bestätigte Datei-Handleschließung nach Transfers, damit verspätete Serverfehler nicht als Erfolg erscheinen.
- Erhalt vorhandener Zieldateien bei abgebrochenen Übertragungen in Arbeitsdateien und Beibehaltung der ursprünglichen Konfliktstrategie beim Fortsetzen.
- Acht Punkte zusätzlicher Abstand zwischen Drei-Punkte-Symbol und Menüpfeil in beiden Panels.
- Bisheriges ⌘W-Verhalten zum Schließen des Fensters durch gezieltes Schließen des aktiven Tabs ersetzt.
- Doppelklick-Aktivierungen zusammengefasst, um versehentlich doppelte Verbindungstabs zu verhindern.

### Bekannte Grenzen und Verifikation

- Details zu tatsächlich ausgeführten Builds, Tests und visuellen Prüfungen stehen in [VALIDATION.md](VALIDATION.md).
- Der Release-Build über SwiftPM und das lokal signierte App-Bundle wurden erfolgreich gebaut und gestartet. Der direkte Xcode-Build war durch ein defektes Plugin der lokalen Xcode-Installation blockiert.
- Passwort-/Keychain-ASKPASS-Authentifizierung ist implementiert, aber noch nicht vollständig mit einem interaktiven Testkonto end-to-end verifiziert.
- Queue und offene Tabs werden noch nicht über App-Neustarts hinweg wiederhergestellt.
- Symlinks und Spezialdateien werden bei Transfers ausdrücklich abgelehnt; Remote-Drag-Export in den Finder fehlt.
- Fortsetzen setzt identische vorhandene Teilinhalte voraus; Remote-Bearbeiten bietet keinen atomaren Versionsvergleich.
- Noch keine Verzeichnissynchronisierung, kein Verzeichnisvergleich, keine Bandbreitenbegrenzung oder Notarisierung. Weitere Grenzen sind im [README](README.md) dokumentiert.
