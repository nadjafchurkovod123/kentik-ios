# Kentik для iPhone

Личный браузер для iPhone — младший брат десктопного Kentik (Windows, Rust/WebView2).
Тёмный интерфейс с фиолетовым акцентом, акула в короне на домашнем экране.

Что будет внутри:

- **Блокировка всей рекламы** — особенно на сайтах с сериалами: всплывающие вкладки и
  попандеры по клику на плеер, рекламные перенаправления, оверлеи поверх видео, реклама
  во встроенных плеерах.
- **Выключатель как в AdBlock** — щит можно выключить везде или только на текущем сайте
  (кнопка со щитом на нижней панели).
- **Настоящий режим инкогнито** — все вкладки инкогнито живут в отдельном непостоянном
  хранилище; когда закрыта последняя из них, куки и кэш исчезают.
- Без тяжёлых функций анонимности десктопной версии — простой и быстрый браузер.

**Установка на iPhone — [INSTALL.md](INSTALL.md)** (AltStore или Sideloadly, бесплатный
Apple ID). Источник AltStore с обновлениями:
`https://raw.githubusercontent.com/nadjafchurkovod123/kentik-ios/main/altstore/source.json`.

## Устройство проекта

| Папка | Что там |
|---|---|
| `Sources/App` | AppDelegate, SceneDelegate, тестовые флаги запуска |
| `Sources/Browser` | Tab, TabManager, BrowserViewController, WebViewFactory |
| `Sources/Blocking` | ContentBlocker, BlockingSettings, FilterLists, ShieldControlling |
| `Sources/Guard` | PopupGuard, RedirectGuard, Scriptlets |
| `Sources/UI` | панели, домашний экран, тема |
| `Sources/Resources` | Info.plist, иконка, обои |
| `KentikTests`, `KentikUITests` | unit- и UI-тесты |
| `tests/fixtures` | HTML-страницы для UI-тестов |

Проект Xcode не хранится в git: его генерирует [XcodeGen](https://github.com/yonaskolb/XcodeGen)
из `project.yml` (`xcodegen generate`).

## Как собирается

Mac не нужен: всё собирает GitHub Actions (`.github/workflows/ios.yml`) на macOS-машине
при каждом push, pull request, ручном запуске и теге `v*`:

1. выбирается самый новый Xcode (с iOS 26 SDK) и самый новый iPhone-симулятор;
2. `xcodegen generate`;
3. поднимается локальный сервер фикстур `python3 -m http.server 8765` из `tests/fixtures`;
4. unit- и UI-тесты в симуляторе; снимки экрана из UI-тестов выгружаются артефактом
   **screenshots**;
5. отдельным шагом — дымовой прогон на настоящих сайтах с рекламой (`RealSitesUITests`):
   снимки «блокировка ВКЛ / ВЫКЛ» рядом в папке `side-by-side` артефакта **screenshots**;
   этот шаг сборку не валит — живые сайты меняются;
6. сборка Release для iPhone **без подписи**, упаковка в `Kentik.ipa` — артефакт **ipa** —
   и проверка IPA (Payload/Kentik.app, bundle id, только arm64 для iPhone);
7. на теге `v*` — GitHub Release с `Kentik.ipa` и новая версия в источнике AltStore
   `altstore/source.json` (CI сам коммитит его в main).

Выпустить версию: поднять `MARKETING_VERSION` в `project.yml` и отправить тег, например
`git tag v1.0.1 && git push origin v1.0.1`.

## Блокировщик рекламы: списки фильтров

Списки собираются на CI (`scripts/filters/build_filters.py`, источники — в
`scripts/filters/sources.json`) и попадают в приложение, поэтому блокировка работает офлайн
с первого запуска:

| Список в приложении | Источники |
|---|---|
| `ads` | EasyList, uBlock filters – Ads, AdGuard Mobile Ads, Peter Lowe |
| `ru` | RU AdList (Lain_13 / dimisa), AdGuard Russian |
| `annoyances` | AdGuard Popups, AdGuard Annoyances (Other, Mobile App Banners, Cookie Notices) |
| `privacy` | EasyPrivacy, uBlock filters – Privacy, RU AdList: счётчики |
| `security` | uBlock filters – Badware risks |

В каждый список добавляются uBlock filters – Unbreak и Quick fixes (исключения WebKit
действуют только внутри своего списка).

**Конвертер** — [AdGuard SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib)
v4.3.1 (GPL-3.0), собирается на CI из исходников по закреплённому коммиту. Он понимает синтаксис
ABP, uBlock Origin и AdGuard (сетевые и косметические правила, `$domain`, `:has()` и т. д.) и
выдаёт JSON для `WKContentRuleList`. Скриптлеты и расширенный CSS (`##+js(...)`, `:has-text`)
в JSON не помещаются — их число видно в отчёте CI («продвинутых»).
Каждая категория конвертируется под две версии WebKit: `s26` (iOS 26+) и `s16` (iOS 16.4–25);
если правил больше лимита WebKit (150 000 на список), категория делится на части. Отчёт с
числом правил, несконвертированных и отброшенных — в логе шага и в Summary запуска.

**Обновления.** `.github/workflows/filters.yml` раз в сутки пересобирает списки и выкладывает их
в релиз с тегом `lists` (`manifest.json` + `*.json.deflate`). Приложение не чаще раза в сутки
(и по «Обновить списки») читает манифест, качает новые файлы, проверяет sha256, компилирует и
только потом подменяет правила; при любой ошибке остаются встроенные списки.

**Скриптлеты AdGuard (YouTube).** Рекламу внутри плеера YouTube списками WebKit не убрать —
она идёт с тех же хостов, что и видео. `scripts/filters/build_adguard.py` берёт правила `#%#`
для YouTube из AdGuard Base (версия для Safari) и официальную библиотеку `@adguard/scriptlets`
и собирает готовые скрипты (`adguard.json`): встроенный — со сборкой IPA, свежий — в релизе
`lists` (ключ `adguard` манифеста; `filters.yml` собирает раз в 6 часов, приложение смотрит
манифест тоже раз в 6 часов). Скрипты ставятся в мир страницы до загрузки документа, только
когда главный фрейм идёт на сайт из набора и щит там включён. Исключение для
`static.doubleclick.net/instream/ad_status.js` (без него YouTube видит блокировщик) лежит в
`scripts/filters/kentik-fixes.txt` и дописывается в каждый список.

**Выключатель.** Общий и «на сайте» (сайт = регистрируемый домен, `m.kinogo.ru` = `kinogo.ru`).
Перед загрузкой страницы на выключенном сайте Kentik снимает списки с веб-вью, поэтому щит
выключается и для самой страницы, и для всех её iframe.

## Где взять IPA

- Релизы: <https://github.com/nadjafchurkovod123/kentik-ios/releases/latest> — `Kentik.ipa`.
- Через AltStore — источник выше, обновления приходят в приложение.
- Сборка любого коммита: **Actions** → запуск **iOS** → артефакт **ipa**.

Как ставить — [INSTALL.md](INSTALL.md).

Платный аккаунт разработчика не нужен: приложение не использует push, iCloud, App Groups
и другие возможности, которые требуют платной подписи.

## Флаги для тестов (только DEBUG)

- `-KentikUITest` — чистое состояние при запуске;
- `-KentikTestRules` — тестовый список правил: блокирует адреса с `/ads/` и прячет `.test-ad`;
- `-KentikStartURL <адрес>` — открыть адрес при запуске;
- `-KentikPersistSession` — в UI-тесте всё же сохранять и восстанавливать вкладки (и историю);
  `-KentikFreshHistory` — начать с пустой истории;
- `-KentikFakeAuth` — тестовый запрос вместо Face ID; `-KentikIncognitoFaceID` /
  `-KentikIncognitoFaceIDOff` — включить / выключить Face ID для инкогнито;
  `-KentikIncognitoGrace <с>` — через сколько секунд на обычных вкладках инкогнито запирается;
- `-KentikNoAdGuard`, `-KentikNoGuard`, `-KentikNoBlocker`, `-KentikWebViewAutoLayout` —
  опыты для сравнения (без скриптлетов AdGuard / защиты / списков / веб-вью как в 1.0.1);
- `KENTIK_DIAG_DIR=<папка>` (переменная окружения) — DiagProbe: состояние фреймов, видео и
  срабатывания правил для живых UI-тестов (`SeriesDiagUITests`, артефакт **diag**).

## Лицензия

GPL-3.0 — см. [LICENSE](LICENSE).
