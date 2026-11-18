## GatherScout: what is worth farming right now

GatherScout is an Auction House helper for **World of Warcraft: Forever**. It scans the Auction House, works out which gathering materials and mob drops are in demand, and shows what **you** can farm profitably and safely at your level and with your skills.

*Interface, mob and node names in English, Russian, German, French, Spanish, Portuguese, Korean and Chinese (simplified and traditional).*

### Features

- **Auction House scan.** A full scan reads the whole AH in a few seconds (the server allows one every 15 minutes). A quick scan checks only ~120 gathering materials. If Auctionator has just done a full scan, GatherScout reuses the result instead of spending its own.
- **Market price that ignores dumping.** The price comes from the cheap part of the market (15–30% of all units) with outliers removed. A handful of items listed far below the rest does not drag it down, and the minimum price is shown separately.
- **Demand.** How many days the units on the AH last at the speed they leave between your own scans, adjusted for listings vs. the 7-day norm and the price trend.
- **Difficulty for you.** Zones where you kill everything rank higher than zones at your own level, where half the mobs can kill you. Elites, enemy faction territory, missing gathering skill and node density are taken into account, and zones far above your level are hidden.
- **Mob drops**: about 4,300 tradeable items, including meat, fangs, cloth, recipes, BoE gear and world drops. Bind-on-pickup, quest items and grey junk are filtered out.
- **Drop chances.** The colour shows the source: white is wowhead data via Questie, light blue is CMaNGOS classic data, green is your own kills. Your statistics blend in gradually.
- **Mob markers (Questie-style).** An icon next to the nameplate and on the target portrait. The mob tooltip shows what drops, the chance, the price, the demand, and whether your skinning skill is high enough.
- **Herb and ore node tooltips**: what the node gives, including gems and other by-products, with price and demand.
- **Item card** with a 21-day chart of minimum price, market price and quantity, plus where to farm the item and which mobs drop it.
- **World map markers.** Mob spawn points on zone maps, zone markers with level and difficulty on continent maps, and a one-click toggle button on the map.
- **Learns from your loot.** It remembers which mobs and zones actually gave you materials, which fills in new Forever content.
- **Everything can be switched off**: a main switch, separate toggles for nameplates, target icon and tooltips, and `/gs off`.

### Auctionator is optional

GatherScout works on its own: it scans, prices and keeps 30 days of daily history by itself. If Auctionator is installed, its history fills the days you did not scan, and its full scans are reused. Auctionator's prices are never used.

### Commands

`/gs` opens the list. `/gs scan` runs a full scan and `/gs quick` a quick one. `/gs on` and `/gs off` toggle the mob markers. `/gs map` toggles the map markers and `/gs nodes` the herb and ore points. Use `/gs minimap` for the minimap button and `/gs reset` to clear the auction data.

### Data and license

Zone, node, mob and loot data is generated from [QuestieDB](https://github.com/Questie/Questie) (GPL-3.0) and [CMaNGOS classic-db](https://github.com/cmangos/classic-db) (GPL-3.0). GatherScout is GPL-3.0-or-later. Source code, issues and releases are at [github.com/markelz0r/GatherScout](https://github.com/markelz0r/GatherScout).

---

## GatherScout — что сейчас выгодно фармить (по-русски)

Сканирует аукцион, считает спрос на сырьё собирательных профессий и на всё, что падает с мобов, и показывает, что тебе выгодно и безопасно добывать на твоём уровне и с твоими навыками. Мобов с нужным дропом помечает иконкой у полоски здоровья, как Questie. Есть подсказки с шансами выпадения, графики за 21 день и метки на карте мира. Auctionator не обязателен.

Команды: `/gs` открывает список, `/gs scan` запускает полный скан, `/gs quick` быстрый, `/gs off` выключает пометки на мобах.
