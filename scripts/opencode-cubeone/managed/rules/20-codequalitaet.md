# Codequalität

Gilt für jede Codeänderung, unabhängig von Sprache und Projekt.

- Die einfachste Lösung zuerst. Sie ist korrekt, lesbar und testbar für die aktuellen Anforderungen.
- Kein Entwurfsmuster ohne Anlass. Ein Muster braucht ein konkretes Signal im Code oder in einer genannten Anforderung, keine mögliche künftige Änderung.
- Vorhandene Mechanismen des Projekts erweitern (DI-Container, Events, Middleware, Basisklassen), keinen zweiten Mechanismus für dieselbe Aufgabe anlegen.
- Die leichteste Form wählen: Funktion, dann Map von Funktionen, dann Interface mit Klassen, dann Klassenhierarchie.
- Komposition vor Vererbung. Vererbung nur für echtes *ist-ein*, nicht zur Wiederverwendung.
- Ein Interface nur, wenn es mindestens zwei Implementierungen gibt oder eine Systemgrenze (externe API, Datenbank, Dateisystem, Uhr, Netzwerk) kapselt, die Tests ersetzen müssen.
- Kein veränderlicher globaler Zustand. Abhängigkeiten über Konstruktor oder Parameter übergeben, kein Singleton und kein Service Locator als Ersatz.
- Fremde Typen (SDK, API-DTOs) bleiben an der Grenze und gelangen nicht in die Fachlogik.
- Namen nennen die Rolle. Ein Musterbegriff steht nur an Code, der das Muster umsetzt.
- Umbau in kleinen Schritten, Tests grün, Verhalten und Struktur nicht im selben Schritt ändern.
- Wird ein Muster eingeführt oder entfernt, in der Antwort nennen: Signal, gewähltes Muster, verworfene einfachere Alternative.

Für Architekturfragen, Erweiterungspunkte, Refactorings und Reviews den Skill `design-patterns` laden.
