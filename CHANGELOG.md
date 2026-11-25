# 1.4.0

- Only the full scan is left: the quick scan searched the materials one by one and took minutes. The button
  on the AH and `/gs scan` run the full scan; `/gs quick` and the Shift+click are gone.
- Auctionator: GatherScout asks Auctionator to run the full scan, so both addons get the data. The server
  allows one full scan per 15 minutes and Auctionator reads only the scans it started, so a scan of
  GatherScout's own used to leave Auctionator without data for 15 minutes. Full scans Auctionator starts
  itself are reused as before. GatherScout no longer searches the AH at all, so it never disturbs
  Auctionator's buying and selling tabs.
- When the server sends no full scan, the data of the last scan stays and the status says when the next
  one is possible.

---

- Остался только полный скан: быстрый перебирал материалы по одному и шёл минутами. Кнопка у аукциона и
  `/gs scan` запускают полный скан; `/gs quick` и Shift+клик убраны.
- Auctionator: GatherScout просит полный скан у Auctionator, и данные получают оба аддона. Сервер даёт
  один полный скан в 15 минут, а Auctionator читает только те сканы, что запустил сам, поэтому собственный
  скан GatherScout раньше оставлял Auctionator без данных на 15 минут. Сканы, которые Auctionator
  запускает сам, используются как и раньше. GatherScout больше совсем не делает поисков по аукциону и
  не мешает вкладкам покупки и продажи Auctionator.
- Если сервер не прислал полный скан, остаются данные прошлого скана, а в статусе видно, когда можно
  следующий.

# 1.3.0

- Interface in English, Russian, German, French, Spanish (EU and Latin America), Portuguese, Korean and
  Chinese (simplified and traditional); mob and herb/ore node names in the client's language.
  Search ignores case for accented Latin letters and Cyrillic too.
- Fishing: what you catch where (zones, coasts and lakes, fishing schools), the catch rate for your fishing
  skill including pole and lure bonuses, schools on the map.
- Fishing schools get their tooltip lines in every client language; the map and the item card call a
  school by the name the game shows.
- Item card: "Where to farm" is one row per place in aligned columns (difficulty, mob, levels, chance,
  zone). A click opens the place's other mobs; the tooltip has the full mob list and all warnings; places
  that do not fit sit behind "N more places".
- World map: spawns close together merge into one marker (with a count) and split again when you zoom in;
  markers are framed in the difficulty color for you and drawn below quest markers. Continent maps show
  one marker per zone; Shift+click on the map button switches best place / best 3 / all. The card's map
  button shows just that item.
- Mobs without a level in the data get the zone's levels (marked "~") until you see one; the level you
  see is remembered. Impossible level ranges are fixed.
- Neutral (yellow) mobs are back in the data: boars, wolves, plainstriders, kodos, zhevras, crawlers,
  owls and more were missing, e.g. Chunk of Boar Meat showed only Corrupted Mottled Boars.
- World drops (scrolls, BoE greens) are no longer tied to the few mobs Questie happens to list.
- Leather and cloth list the mobs that really drop them; chances below 1% are not offered as farm spots.
  An unknown chance shows "??".
- Auction House: a repeated item list from the server (e.g. after Auctionator's scan) no longer resets
  the scan status or the 15-minute timer; the AH buttons fit their labels in every language.
- Demand is now mostly how many days the units on the AH last at the speed they leave between your scans:
  about a day or less is high, 1–3 days average, more is low. A big stock that sells out fast (silk, linen,
  wool, copper) used to show "average". Until your scans span a few hours it says "few scans" in grey
  instead of a confident "average"; the item card shows the days of stock. The price change (+25%) moved
  from the Demand column to the Price column, where it belongs.
- ScoutScore (0–100, colored) replaces "~income/h": how good an item is for you to earn with right now
  against everything else in the list. It weighs the price, how easy it is for you to get (mobs below your
  level count as easy, above you as hard), the drop chance, demand and whether the AH buys enough of it.
  The gold-per-hour figure looked exact but was not. The column now sorts by what it shows (it used to sort
  by a hidden rating), and "Best place" is the most worthwhile place for you, not just the easiest one.

---

- Интерфейс на английском, русском, немецком, французском, испанском (Европа и Латинская Америка),
  португальском, корейском и китайском (упрощённом и традиционном); имена мобов, трав и жил — на языке
  клиента. Поиск не различает регистр и для букв с диакритикой, и для кириллицы.
- Рыбалка: что где ловится (зоны, побережья и озёра, косяки рыбы), доля улова при твоём навыке с учётом
  удочки и наживки, косяки на карте.
- Подсказка у косяков рыбы работает на любом языке клиента; карта и карточка предмета называют косяк так
  же, как игра.
- Карточка предмета: «Где добывать» — по строке на место, колонками (сложность, моб, уровни, шанс, зона).
  Клик раскрывает остальных мобов места; в подсказке весь список мобов и все предупреждения; что не
  влезло — за строкой «ещё N мест».
- Карта мира: близкие точки сливаются в одну метку (с числом) и расходятся при приближении; рамка метки —
  цвет сложности для тебя, метки под квестовыми. На карте континента — одна метка на зону; Shift+клик по
  кнопке на карте: лучшее место / лучшие 3 / все. Кнопка карты в карточке показывает только этот предмет.
- Мобы без уровня в данных получают уровни зоны (с пометкой «~»), пока ты их не увидишь; увиденный уровень
  запоминается. Невозможные диапазоны уровней исправлены.
- Вернулись нейтральные (жёлтые) мобы: не хватало кабанов, волков, равнинных бегунов, кодо, зебр, крабов,
  сов и других — например, у «Куска кабанины» был только Оскверненный крапчатый вепрь.
- Мировой дроп (свитки, зелёные BoE-вещи) больше не привязан к паре мобов, которых случайно упоминает Questie.
- Для кожи и ткани — мобы, с которых они правда падают (снимаются); шанс меньше 1% не предлагается как
  место фарма. Неизвестный шанс показывается как «??».
- Аукцион: повторный список лотов от сервера (например, после скана Auctionator) больше не сбрасывает
  статус скана и 15-минутный таймер; кнопки у аукциона вмещают надпись на любом языке.
- Спрос теперь в первую очередь — на сколько дней хватит лотов на аукционе при той скорости, с которой
  они уходят между твоими сканами: около дня и меньше — высокий, 1–3 дня — средний, дольше — низкий.
  Раньше большой запас, который быстро раскупают (шёлк, лён, шерсть, медь), показывался как «средний».
  Пока твои сканы не охватили несколько часов, вместо уверенного «средний» серым написано «мало сканов»;
  в карточке предмета видно, на сколько дней хватит запаса. Изменение цены (+25%) переехало из колонки
  «Спрос» в колонку «Цена».
- ScoutScore (0–100, с цветом) вместо «~доход/ч»: насколько предмет сейчас выгоден тебе для заработка по
  сравнению со всем остальным в списке. Учитывает цену, насколько легко тебе его добыть (мобы ниже твоего
  уровня — легко, выше — тяжело), шанс дропа, спрос и берёт ли аукцион столько. Золото в час выглядело
  точной цифрой, но ею не было. Колонка теперь сортируется по тому, что показывает (раньше — по скрытому
  рейтингу), а «Где лучше всего» — самое выгодное для тебя место, а не просто самое лёгкое.

# 1.2.0

First public release.

- Auction House scan: full (whole AH in seconds, once per 15 min) and quick (gathering materials only).
  Market price ignores dumping: cheap part of the market, outliers dropped, the minimum shown separately.
- Demand (scarcity vs the 7-day norm, price trend, units leaving the AH) and difficulty for your level.
- Gathering materials and ~4,300 tradeable mob drops with drop chances (wowhead via Questie, CMaNGOS,
  refined by your own kills).
- Nameplate and target icons, mob and herb/ore node tooltips, 21-day charts, world map markers with a
  one-click toggle.
- Works without Auctionator; uses its history when it is installed.

---

Первый публичный релиз.

- Скан аукциона: полный (весь аукцион за секунды, раз в 15 минут) и быстрый (только сырьё).
  Рыночная цена не ведётся на демпинг: дешёвая часть рынка без выбросов, минимум показан отдельно.
- Спрос (лотов против нормы за 7 дней, тренд цены, сколько уходит с аукциона) и сложность для твоего уровня.
- Сырьё собирательных профессий и ~4 300 продаваемых предметов с мобов с шансами выпадения (wowhead из
  Questie, CMaNGOS, уточняются по твоим убийствам).
- Иконки на неймплейтах и у цели, подсказки на мобах, траве и жилах, графики за 21 день, метки на карте
  мира с кнопкой вкл/выкл.
- Работает без Auctionator; если он стоит — берёт его историю.
