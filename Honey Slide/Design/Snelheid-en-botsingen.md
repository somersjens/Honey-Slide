# Analyse: band, tussenranden en dubbele vaart

Status: uitgevoerd en geverifieerd op 11 oktober 2026. De analyse hieronder beschrijft de uitgangssituatie; de implementatie en controles staan onderaan.

De gewenste combinatie is haalbaar: ongeveer dubbele vaart door de omgeving, dezelfde 6,6 seconden tussen vragen en solide tussenranden met vrije ruimte vóór de neus en achter het uiteinde. Hiervoor moeten de wereldafstand, leesbaarheid en botsingen gezamenlijk worden aangepast.

## Wat de overlap veroorzaakt

`Core/HoneySlideSimulation.swift`, regels 174–188, kiest alleen de eerste onbeantwoorde vraag. De geleiding begint zodra het middelpunt van de band de neus van de muurtjes bereikt. De voorkant van de band kan de neus dan al raken. Na `markSelected` wordt deze vraag overgeslagen, hoewel de muurtjes nog 60 wereldeenheden voorbij de potten doorlopen: 0,273 seconde bij de huidige snelheid, plus de lengte van de band zelf.

Regels 220–226 beperken de positie van het middelpunt tot een kanaal dat geleidelijk van ±0,33 naar ±0,22 vernauwt. De bandbreedte telt daarbij niet mee. `configureViewport` berekent die breedte wel voor de buitenranden, maar dezelfde informatie wordt niet gebruikt voor de tussenranden.

De ruimte tussen het middelpunt en de dichtstbijzijnde muur is bij een toegestane afwijking van 0,22 slechts `(0,33 − 0,025 − 0,22) × 740 = 62,9` logische pixels. De huidige halve bandbreedte is circa 146 pixels op een telefoon van 852×393 en 210 pixels op een iPad van 1194×834. Het kanaal kan daardoor geen garantie tegen overlap geven.

Een controle met de echte Foundation-simulatie, vaste baanseed 42 en stuurdoel 0,32 reproduceren dit op beide formaten:

| Moment | Telefoon: berekende overlap | iPad: berekende overlap |
|---|---:|---:|
| Middelpunt passeert de ingang | 155,5 logische pixels | 219,3 logische pixels |
| 0,15 s na antwoordkeuze, stuurdoel 0,66 | 151,8 logische pixels | 215,5 logische pixels |

Bij het tweede meetpunt bevinden zich nog 27 wereldeenheden muur vóór het middelpunt. De waarden meten overlap van de bestaande dwarsbreedte met de muur, geen pixelmasker van de afbeelding. Ze tonen wel concreet dat de huidige botsingslogica de band boven de muur toestaat.

## Botsingen die de volledige band bewaken

Gebruik één definitie van het contactoppervlak van de band, afgeleid van de daadwerkelijk getekende bandafmetingen per viewport. De voorste en achterste omvang moeten op dezelfde grondprojectie liggen als de muurtjes. Neem de kanteling mee of beperk die waar de band anders niet in het kanaal past. De armen en het hoofd van de beer horen niet bij dit contactoppervlak.

Behandel ieder muurtje als een obstakel met vaste wereldpositie, breedte, begin en einde. De botsing blijft actief onafhankelijk van het beantwoorden of promoveren van een vraag. Zolang een deel van de band het muurtje in de lengterichting overlapt, moet zijn hele contactoppervlak vrij van de muur blijven. Pas wanneer de achterkant voorbij het laatste uiteinde is, mag de band weer van kanaal wisselen.

De kanaalgrens moet uit de echte vrije ruimte volgen, niet uit de constante 0,22. Als eenvoudige controle voor de rechte zijwand geldt: toegestane afwijking vanaf het kanaalmidden = halve kanaalbreedte − halve muurdikte − halve bandbreedte − speling. Met de bestaande breedte en 12 pixels speling geeft dit ongeveer ±0,091 voor de telefoon en ±0,005 voor de iPad. De beperkte ruimte op iPad maakt een gemeenschappelijk model voor tekenen en botsingen extra belangrijk.

Bij de neus en het achterste uiteinde is een afgeronde botsingsvorm nodig. Een vaste volledige-bandmarge die plotseling wordt aangezet kan de band tientallen pixels zijwaarts laten springen. Een controle van de beweging tussen twee simulatiestappen, met contact tegen de afgeronde uiteinden, moet de band langs de neus laten glijden en de snelheid door de muur verwijderen. Zo blijven de plekken vlak vóór en achter het obstakel bruikbaar. Een brede blokkade rond de volledige vraag zou deze gewenste vrijheid wegnemen.

Bij zijcontact verwijder je alleen de snelheid die de muur in wijst. Sturen van de muur af blijft mogelijk. Een stuurcommando hoeft de band daarbij niet automatisch naar het kanaalmidden te trekken. Een gekozen antwoord blijft één gebeurtenis op de potpositie; de fysieke muren blijven daarna afzonderlijk bestaan.

## Vaart en vraagritme

De camera, baan, bomen en muurtjes gebruiken nu dezelfde wereldklok. De vraagafstand wordt al berekend als `forwardSpeed × checkpointInterval`, zowel in de regels als bij het aanmaken van rijen. Daardoor kan de daadwerkelijke snelheid worden verdubbeld zonder de tijd tussen vragen te halveren.

| Onderdeel | Huidig | Voorstel |
|---|---:|---:|
| Voorwaartse snelheid | 220 eenheden/s | 440 eenheden/s |
| Tijd tussen vragen | 6,6 s | 6,6 s |
| Afstand tussen vragen | 1.452 eenheden | 2.904 eenheden |
| Bochtlengte | 600–850 eenheden | 1.200–1.700 eenheden |
| Rechte aanloop na een rij | 280–380 eenheden | 560–760 eenheden |
| Gereserveerde rechte aanloop vóór de volgende rij | 350 eenheden | 700 eenheden |
| Muurtjes vóór / achter de potten | 210 / 60 eenheden | 420 / 120 eenheden |
| Blokjes per muurtje, met dezelfde bloklengte | 9 × 30 eenheden | 18 × 30 eenheden |
| Extra stroming van de honing | 58 eenheden/s | 116 eenheden/s |

De langere bochten behouden ongeveer dezelfde tijdsduur en hoekverandering per seconde. Alleen snelheid en vraagafstand veranderen zou langere lege rechte stukken geven, gecombineerd met bochten die in de helft van de tijd worden afgelegd. Met een gelijkblijvende baanbreedte kan de snellere beweging de band nog vaker tegen de buitenrand brengen; dit moet met onbeheerde ritten en echt sturen worden beoordeeld.

Houd de breedte van de baan, camerabrandpuntsafstand, boomafstand van 145 eenheden en bloklengte van de buitenrand van 72 eenheden gelijk. Zo trekken bomen, voegen en oppervlaktegolven daadwerkelijk sneller voorbij. Het verdubbelen van alle afmetingen, inclusief perspectief en decorafstand, zou veel van de zichtbare versnelling weer opheffen.

Behoud de stuurrespons, het openen van de potten (0,42 s), verzamelen (0,65 s) en feedbackanimaties op hun bestaande tijdsduur. De volledige simulatieklok twee keer zo snel afspelen zou ook deze onderdelen versnellen. De extra honingstroming kan wel met de voorwaartse snelheidsfactor worden geschaald.

## De antwoorden moeten leesbaar blijven

De grotere vraagafstand heeft een meetbaar neveneffect. Een nieuw actief antwoord staat nu op een projectiediepte van circa 0,191. Bij dubbele snelheid en dezelfde bedenktijd wordt dat 0,108. De huidige extra verkleining van verre potten, met exponent 1,4, brengt de potbreedte van circa 36,5 naar 16,4 logische pixels: 55% kleiner.

Een schaal die lineair met de perspectiefdiepte meegroeit, met dezelfde contactgrootte van 1,88, geeft bij de nieuwe afstand circa 37,2 pixels. Dat herstelt ongeveer de huidige begingrootte. De baanplaatsen groeien eveneens lineair met diepte, waardoor de verhouding tussen potbreedte en afstand tussen de drie opties constant kan blijven. De overgang door contact en passage moet daarbij ook een doorlopende waarde en snelheid krijgen.

Dit schaalt de antwoordafbeeldingen, terwijl hun vaste wereldpositie en botsingsmoment behouden blijven. De centrale som blijft op de HUD staan en de volgende rij blijft op zijn eigen positie zichtbaar worden.

## Verificatie bij uitvoering

1. Meet echte afstand en minstens twintig opeenvolgende vraagcontacten: 440 eenheden/s en gemiddeld 6,6 s tussen contacten, zonder toenemende afwijking.
2. Test alle drie kanalen op telefoon en iPad, met startposities dicht bij beide muurtjes, aanraking, slepen, toetsbesturing en loslaten.
3. Controleer de volledige band tegen neus, zijkant en achterste uiteinde, inclusief kanteling en volledige passage ná het kiezen van het antwoord.
4. Test oversteken vlak vóór de eerste fysieke aanraking en direct nadat de achterkant het einde vrij heeft gemaakt. Binnen de muurtjes mag oversteken niet lukken.
5. Controleer beweging over een lage framesnelheid en losse lange frames: geen doorgang door muren, dubbele score of verdwijnende vraagrij.
6. Beoordeel bochten, antwoordleesbaarheid en stuurgevoel met de productierenderer op beide schermformaten. Behoud de bestaande checks voor buitenranden, projectie, vaste rijen, kanaalcontact, potpassage en verzamelen.

Aanbevolen volgorde: eerst het gemeenschappelijke contactoppervlak en volledige muurpassage oplossen; vervolgens snelheid en lengteverhoudingen samen aanpassen; daarna de verre potschaal en stroming afstemmen en de combinatie verifiëren.

## Uitgevoerd

De vaart is 440 eenheden/s met 2.904 eenheden tussen vaste vraagrijen. Twintig opeenvolgende contacten zijn gecontroleerd op precies 6,6 seconden tussenruimte. Bochtlengtes, rechte aanlopen en muurlengtes zijn verdubbeld; boomafstand, voegafstand en perspectief blijven gelijk. De honingstroming is 116 eenheden/s en de potten schalen lineair met diepte, zodat een nieuw actief antwoord ongeveer 37,23 logische pixels breed blijft. Stuurrespons, luiken en feedback behouden hun bestaande tijdsduur.

Een gedeeld geometriebestand definieert bandmaat, beeldverhouding en dobberen voor tekenen en botsingen. Een ruime ovale contactvorm omvat de zichtbare opblaasband, inclusief kanteling; armen en hoofd tellen niet mee. De botsingscontrole gebruikt de geprojecteerde zijvlakken en verhoogde bovenkanten van beide muren. Hij blijft actief na antwoordkeuze en eindigt pas wanneer de volledige band vrij is. Afgeronde contactuiteinden geven geleidelijk ruimte; de oorspronkelijke stuurwens blijft staan. Het eerste fysieke contact bij de neus kiest het kanaal, zodat perspectief geen verkeerde kanaalkeuze met een zijwaartse sprong veroorzaakt.

Op tablet is de maximale bandbreedte van 28,5% naar 27% van het scherm gebracht. Daardoor past hij met speling in het middelste kanaal. Waar een grotere kanteling niet past, wordt alleen die kanteling beperkt. Dezelfde geometrie blijft geldig bij schermformaatwijzigingen en Verminder beweging.

De volledige Foundation-controles en de Debug iOS Simulator-build slagen. Aanvullende tests controleren de bandvorm over 121 dwarsdoorsneden: ingang, zijcontact, geselecteerde achterstukken, alle kanalen, vier schermformaten, Verminder beweging, schermwissels en lange frames. De band beweegt weer op de eerste simulatiestap na volledige vrijgave. De productiebeelden zijn beoordeeld op telefoon en tablet, ook tijdens laat oversturen en na een antwoord. Voelen en framerate op fysieke apparaten zijn nog niet gemeten.
