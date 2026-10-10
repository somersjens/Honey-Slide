# Honey Slide — performanceanalyse en uitgevoerde verbeteringen

Datum: 10 oktober 2026.

## Conclusie

De haperingen kwamen vooral uit de renderketen. De spelregels, besturing en
vraagverwerking kosten vrijwel geen tijd vergeleken met het beeld. Een
hergebruikte SwiftUI Canvas-symbolweergave bleek bovendien niet hetzelfde als
een hergebruikte, kant-en-klare afbeelding: de renderketen bleef de paden,
gradients en tekst binnen veel bomen en potten verwerken.

De belangrijkste verbeteringen zijn uitgevoerd in `HoneySlidePlayfield.swift`
en `Core/HoneySlideProjection.swift`. De live iPhone-test ging van circa 19 naar
59 updates per seconde; de iPad-test bereikte eveneens circa 59. Een herhaalde
vergelijking op een verder idle host bevestigde 18,00 → 59,23. De CPU-tijd
voor het voorbereiden van dezelfde spelsituaties daalde ongeveer 55–58%.

Dit zijn simulator- en Mac-metingen. Ze bewijzen minder werk en veel regelmatigere
updates, maar zijn geen meting van gepresenteerde GPU-frames op een fysieke iPhone.

## Hoe is gemeten?

1. De oorspronkelijke renderer, simulatie en projectieregels zijn bewaard als
   nulmeting vóór de wijzigingen.
2. Een offscreen runner compileert de daadwerkelijke renderer en core met `-O`.
   Na vier opwarmbeelden meet hij zestig opeenvolgende beelden per situatie:
   naderen, goed antwoord, fout antwoord en bocht. Elke situatie draait op
   iPhone- en iPad-afmetingen, met dezelfde rasterisatieschaal van 2.
3. Instruments Time Profiler is gebruikt op de oorspronkelijke Mac-renderer en
   op de levende iPhone-simulator. Hiermee zijn ook kosten buiten de eigen
   tekenfuncties onderzocht, waaronder layout, padgrenzen en Metal-encoding.
4. Een afzonderlijke simulator-app gebruikt dezelfde renderer en pure engine.
   Hij rijdt 32 seconden met sturen, goede/foute botsingen, schuifjes en effecten.
   De eerste twee seconden tellen niet mee voor de updatefrequentie. Deze app
   gebruikt een eigen container en verandert geen spelersvoortgang.
5. Een core-benchmark heeft 99.000 simulatiestappen en 250 antwoordovergangen
   over zes rekenthema's gemeten. Een oude snapshot bleef tijdens de volgende
   stap bestaan, zodat kopiëren van gedeelde arrays ook werd meegenomen.

Er is onderscheid tussen CPU-voorbereiding, geleverde spelupdates en werkelijk
gepresenteerde frames. `ImageRenderer.cgImage` en de eigen tekenfuncties meten
niet alle latere GPU-arbeid. Een display-linkcallback bewijst op zichzelf ook
niet dat het beeld al op het scherm is verschenen. De eerste nulmeting in de
simulator is daarom apart herhaald zonder gelijktijdige builds.

## Gevonden knelpunten en maatregelen

### 1. Herhaalde vectorweergave van vaste illustraties — grootste effect

Honderden bomen en planten en meerdere rijen potten worden per beeld geplaatst.
Hun symbolen bevatten tientallen vormen, schaduwen, gradients en soms tekst.
`Equatable` hielp de SwiftUI-viewstructuur, maar voorkwam niet alle verwerking
van de onderliggende vectortekenlijst. Instruments liet veel werk zien in
padgrenzen, getransformeerde tekenlijsten en Metal-rendercommando's.

**Uitgevoerd:** een echte afbeeldingscache met `ImageRenderer` en `NSCache`.
Elke boomvariant, plantvariant, gesloten pot en genummerde pot wordt eenmaal
gerasteriseerd en vervolgens als afbeelding geplaatst. Het bestaande artwork
blijft de bron. De goede pot die naar de teller vliegt gebruikt dezelfde cache.
Alleen het bewegende schuifje wordt tijdelijk apart getekend.

De numerieke werkset beperkt zich tot de eerste vier rijen, zodat komende
vragen kunnen worden voorbereid zonder alle zestien rijen als unieke
potafbeeldingen te bewaren. De cache heeft limieten van 64 objecten en 48 MiB
aan opgegeven afbeeldingskosten; `NSCache` kan bij geheugendruk eerder vrijgeven.
Een experiment met alleen `drawingGroup()` leverde onvoldoende verbetering
en is vervangen door deze expliciete cache.

### 2. Duizenden identieke projectieberekeningen

De nulmeting deed ongeveer 14.000 volledige projecties per beeld. Elke golf
bewaarde meerdere contouren; op vrijwel dezelfde diepte werden baanbreedte,
hoogte en de sinusankers van de bocht telkens opnieuw berekend.

**Uitgevoerd:** één `HoneySlideProjection` per frame. Breedte/hoogte zijn
onafhankelijk van de gereden afstand en worden eenmaal in een statische tabel
berekend. De horizontale bochtprojectie wordt per frame gedeeld via fijnere
monsters dichtbij en grotere intervallen in de verte. Volledige projecties
daalden van ongeveer 14.052 naar 1.054 per beeld in de gemeten nadering, circa
92,5% minder. De vele contourpunten gebruiken daarna goedkope interpolatie.

De exacte projectie slaat daarnaast de bochtberekening over wanneer de
landingszone recht is. Botsingen, potplaatsing en scheidingswanden gebruiken
nog steeds de exacte regels. De cache wordt alleen gebruikt voor de getekende
baan, omgeving en honing.

**Regressiecontrole:** 1,3 miljoen coördinaten over tien minuten baan,
inclusief de horizon, tabelovergangen en camera-fallback. Maximale afwijking:
0,338 logische pixel, onder de grens van 0,5 pixel.

### 3. Veel afzonderlijke baanrand- en scheidingscommando's

De baanrand bestond uit honderden overlappende lijntjes met een eigen breedte.
Elke wand tussen antwoorden tekende zijn honingrand ook per blok opnieuw.
Deze details hadden vaste wereldposities, maar hun tekenopdrachten hoefden
niet afzonderlijk te blijven.

**Uitgevoerd:** doorlopende vlakken voor de perspectivische baanrand en
gebundelde voegen. De oranje rand, gele honing en glans van elke scheiding
worden als drie samengestelde vlakken getekend. De negen fysieke wandblokken
en hun wereldposities blijven behouden. De gemeten Canvas-strokeaanroepen
daalden in de nadering van circa 1.714 naar 613 per beeld. Dit is een telling
van Canvas-aanroepen, geen telling van uiteindelijke Metal-drawcalls.

### 4. Meerdere bewegende lagen over het hele scherm

De baan en de twee lagen honing rond de band hadden elk een eigen groot Canvas,
met de beer als afzonderlijke SwiftUI-weergave daartussen. Dat veroorzaakt
extra compositiewerk en laat onafhankelijke lagen op verschillende momenten
vernieuwen. Er was ook een effecten-Canvas wanneer geen effect zichtbaar was.

**Uitgevoerd:** baan, achterste golven, beer en voorste golven staan in één
opaque Canvas met één simulatiesnapshot. De volgorde blijft hetzelfde. Het
effecten-Canvas bestaat alleen tijdens een zichtbare vlucht of rode straf.
De gewone HUD is apart gehouden en verandert op gebeurtenissen.

### 5. Onnodig detail onder de zichtbare pixelgrootte

Ook zeer verre, minder dan een pixel hoge golven kregen meerdere gevulde
volumes en gradients. De hoeveelheid detail kostte veel meer dan het visueel
opleverde.

**Uitgevoerd:** elke golfcrest blijft op zijn bestaande wereldpositie. Het
volume en de schaduw worden geleidelijk toegevoegd tussen dieptes 0,12 en
0,18. Dichtbij blijven de volledige golven, kolken en glanslagen behouden.
Er worden bij die grens geen nieuwe golf- of baanrijen aangemaakt. Contouren
gebruiken bovendien `CGMutablePath` en buffers met vooraf gereserveerde ruimte.

### 6. Beeldklok en HUD-updates

Een Combine-timer van 1/60 seconde loopt onafhankelijk van de schermverversing.
Een timer kan een update afleveren op een ongunstig moment voor presentatie.
De rode straf veranderde daarnaast elke frame de invoer van de hele HUD.

**Uitgevoerd:** `CADisplayLink` met een gewenste 60-Hz-cadans, ook op ProMotion.
De verstreken tijd bepaalt nog steeds de gereden afstand; een gemist frame
vertraagt de spelwereld niet. Bij pauzeren, uit beeld gaan of verlaten wordt
de link gestopt. Een zwak doelobject voorkomt een retain-cycle.

De rode −1 pulseert en verdwijnt in de effectenlaag. De HUD ontvangt alleen
de gebeurtenis dat de straf zichtbaar is, waardoor de pauzeknop, teller en
vraagachtergrond tijdens die animatie niet elke frame hoeven te veranderen.

## Wat blijkt géén belangrijk knelpunt?

| Onderdeel | Gemeten gemiddelde | p95 | Betekenis |
|---|---:|---:|---|
| Simulatiestap | 0,00017 ms | 0,00025 ms | Besturing en collision checks zijn zeer licht. |
| Antwoord verwerken en volgende rij voorbereiden | 0,00494 ms | 0,00833 ms | Geen reden om de spelregels asynchroon te herschrijven. |
| Voorbereiding per rekenthema | 1,49 ms | maximaal 5,25 ms | Werk vóór het spelen; niet iedere frame. |

Audio-effecten gebruiken al vooraf geladen PCM-buffers en een bestaande
audio-engine. Haptische generators worden vooraf voorbereid. Er is geen
synchroon audio-bestanddecodepad bij iedere botsing gevonden. Publicaties in
`GameViewModel.sync()` zijn bovendien begrensd tot daadwerkelijk veranderde
waarden en antwoordgebeurtenissen. Deze onderdelen zijn niet onnodig aangepast.

## Gemeten resultaten

CPU-voorbereiding van het offscreen beeld, mediaan in milliseconden:

| Situatie | iPhone vóór | iPhone na | iPad vóór | iPad na |
|---|---:|---:|---:|---:|
| Nadering | 4,68 | 2,02 | 4,53 | 2,00 |
| Goed antwoord | 4,60 | 1,94 | 4,46 | 2,00 |
| Fout antwoord | 4,62 | 1,98 | 4,53 | 1,97 |
| Bocht | 4,60 | 1,96 | 4,57 | 1,94 |

De verbetering is circa 55–58%. Elke situatie omvat zestig gemeten beelden
na opwarming. De ruwe data staan in `renderer-before.json` en
`renderer-after.json`; tijden met profiling tellen ook beperkte meetoverhead mee.

Eerste live iPhone-simulatorvergelijking, 30 gemeten seconden:

| Maat | Vóór | Na |
|---|---:|---:|
| Geleverde spelupdates per seconde | 19,39 | 58,93 |
| Gemiddeld update-interval | 51,57 ms | 16,97 ms |
| p95 update-interval | 165,44 ms | 16,67 ms |
| Intervallen langer dan 25 ms | 349 | 29 |
| Gemiddelde eigen wereld-encoding | 3,96 ms | 1,72 ms |

De iPad (A16)-simulator leverde 58,87 updates per seconde, een p95-interval van
16,67 ms en 33 intervallen boven 25 ms. Gemiddelde wereld-encoding: 1,51 ms.
Simulatorwaarden variëren met belasting van de Mac en zijn geen toestelgarantie.

Herhaalde iPhone-vergelijking zonder gelijktijdige builds of offscreen renders:

| Maat | Vóór | Definitieve versie |
|---|---:|---:|
| Geleverde spelupdates per seconde | 18,00 | 59,23 |
| Gemiddeld update-interval | 55,55 ms | 16,88 ms |
| p95 update-interval | 171,82 ms | 16,67 ms |
| Langste update-interval | 346,89 ms | 42,82 ms |
| Intervallen langer dan 25 ms | 324 | 22 |
| Gemiddelde eigen wereld-encoding | 4,20 ms | 1,61 ms |

Dat zijn ongeveer 3,3 keer zoveel updates per seconde en 93% minder lange
intervallen. De resterende 22 lange intervallen betekenen dat ook deze
simulatorrun nog enkele gemiste updates bevatte. Zie `iphone-before-repeat.json`
en `iphone-after-repeat.json`. De bestaande speler-app was tijdens deze tests
niet actief; er is gemeten met de afzonderlijke performance-app.

## Validatie en grenzen

- De gameplaychecks slagen: complete 20/30/40/50-vragensessies, +1/−1 met
  nulvloer, vaste rijen, botsingen, fysiek geleiden door scheidingen, schuifjes,
  constante wereldsnelheid bij onregelmatige frames, pauzeren en eindanimaties.
- Nieuwe controles toetsen de projectiecache tegenover de exacte berekening.
- De daadwerkelijke renderer is visueel gecontroleerd op telefoon/tablet,
  inclusief goede en foute impact, potverhoudingen en landschap.
- De iOS Simulator Debug-build en fysieke iOS Release-build compileren.
- De Mac was vergrendeld. Interactieve bediening via het simulatorscherm was
  daardoor niet beschikbaar; de automatische tests en rendermetingen liepen wel.
- Instruments Animation Hitches rapporteerde dat de simulator dit instrument
  niet ondersteunt. Time Profiler werkte wel. Er is dus geen ongefundeerde claim
  dat fysieke apparaten gegarandeerd elke frame binnen 16,67 ms presenteren.

## Vervolgcontrole op echte apparaten

Voor vrijgave: profileer een Release-build op de oudste ondersteunde iPhone en
een iPad. Meet met Game Performance/Animation Hitches de gepresenteerde FPS,
CPU/GPU-frametijd en koude texture-upload rond het eerste antwoord. Speel ook
enkele volledige sessies na elkaar om geheugen en thermische belasting te
controleren. Een 60-FPS-beeld heeft per frame 16,67 ms beschikbaar; een gemiddelde
alleen is niet voldoende, vooral de langste frames moeten binnen budget blijven.

Als de GPU daar nog het budget overschrijdt, is de eerstvolgende gerichte stap
het bundelen van de resterende bewegende honingvlakken in een mesh/shader.
Verlaag niet meteen de besturingsfrequentie of de wereldsnelheid. Op basis van
de huidige metingen was een volledige herschrijving van de engine niet nodig.

Reproduceren: zie `Tests/README.md` en `Tools/honey_performance.py`.
Alle meetdata zijn lokaal opgeslagen; de test-app leest geen spelersgegevens.

De oorspronkelijke drie gewijzigde bronbestanden staan in `baseline.zip` voor
herhaling met `--source-dir` (uitpakken buiten de Xcode-bronmap). De hashes van
de gemeten definitieve bron staan in `sources.json`.
