# Icons

Phosphor ist der Icon-Satz für Buttons, Navigation, leere Zustände und Status. Eine ausdrückliche andere Vorgabe gilt vorrangig.

- Gewicht `regular`, Größe passend zur Schrift (meist 16 oder 20).
- Paket nach Stack: `@phosphor-icons/react`, `@phosphor-icons/vue`, `phosphor-svelte`. Kein zweites Icon-Paket daneben.

## Projekticon beim ersten Anlegen

Beim ersten Erstellen von Anwendung oder Repository ein Phosphor-Icon wählen, dessen Motiv zur Aufgabe passt. Dasselbe Icon danach nicht mehr austauschen.

Das Icon selbst trägt den cube-one-Farbverlauf, der Hintergrund ist transparent:

- Verlauf entlang des Zeichens, links oben nach rechts unten: `#F7941D` → `#F47A27` → `#F05037`
- Phosphor-Gewicht `bold` für favicons und `regular` für in App Logo
- Keine Fläche, kein abgerundetes Quadrat, keine eigene Hintergrundfarbe
- Quelle: `assets/icon.svg`, dazu `assets/icon.png` mit 1024 px und Alphakanal

Dieselbe Datei ist das Icon an allen drei Stellen:

- Git: `assets/icon.png` ist das Projekticon und das Bild für den Repository-Avatar
- Webanwendung: Favicon, `apple-touch-icon` und App-Icon aus dieser Datei, am üblichen Ort des Frameworks (`app/icon.png`, `public/favicon.ico`)
- Desktop-App: dasselbe Bild als Anwendungsicon (`.ico`, `.icns` und die PNG-Größen des Bundlers)

## Personenbilder

Profilbilder ohne eigenes Foto kommen von DiceBear Slice auf `https://avatar.cubeone.de/10.x/slice/svg`. Seed ist der Anmeldename, URL-kodiert.

`https://avatar.cubeone.de/10.x/slice/svg?seed=ANMELDENAME&backgroundColor=e8e4dc&bodyColor=a5a58d,b98b73,8e9aaf,9c8a94,8fa38f,b0a58c&size=100`

Ein selbst hochgeladenes Profilbild bleibt vorrangig.

# Schrift

Inter, selbst gehostet. Fallback: `system-ui, -apple-system, sans-serif`.

- Fließtext 14 px, Zeilenhöhe 1.5, Gewicht 400
- Überschriften Gewicht 600, Zeilenhöhe 1.25, Buchstabenabstand `-0.025em`

# Oberfläche

Helles Theme ist der Ausgang, ein dunkles Theme bleibt möglich. Eine andere Vorgabe gilt vorrangig.

- Primärfarbe `#F47A27`, Hover `#F05037`, helles Orange `#F7941D`
- Erfolg `#16a34a`, Warnung `#d97706`, Gefahr `#C0392B`, Info `#0ea5e9`
- Hintergrund `#F5F3F0`, Fläche `#FFFFFF`, Text `#1A1A1A`, gedämpfter Text `#5A5A5A`
- Dunkel: Hintergrund `#000000`, Fläche `#0A0A0A`, Text `#F0F0F0`
- Radien für Karten und Flächen: 6 / 10 / 14 px
- Karten: weiße Fläche, 1 px Rahmen, Radius 14 px, leichter Schatten
- Eingaben: Höhe 40 px, Radius 10 px, Fokusring `2px` in der Primärfarbe mit 10 % Deckkraft

## Buttons

Primär- und Sekundärbutton haben dieselbe Form. Es sind Rechtecke, deren Rundung nur in der linken oberen und rechten unteren Ecke sitzt. Die Kanten oben und unten bleiben gerade.

Sie stehen inline nebeneinander. Der Text ist zentriert und einzeilig.

- Primärbutton: volle Füllung in `#F47A27`, Text `#FFFFFF`, Rahmen in derselben Farbe. Hover `#F05037`
- Sekundärbutton: Füllung wie die Fläche dahinter, Text in der normalen Textfarbe, Rahmen 1 px in einer sichtbaren neutralen Farbe
