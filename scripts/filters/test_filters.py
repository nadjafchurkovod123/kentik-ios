#!/usr/bin/env python3
"""Проверки сборщиков: правила `$domain=` для фреймов (build_filters.add_frame_scoped) и
скриптлеты для фреймов (build_adguard: синтаксис uBO, исключения, сборка скрипта).

Запуск: python3 -m unittest discover -s scripts/filters -p "test_*.py" -v
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import build_adguard as adg  # noqa: E402
import build_filters as bf  # noqa: E402


def rule(url_filter, action="block", **trigger):
    t = {"url-filter": url_filter}
    t.update({k.replace("_", "-"): v for k, v in trigger.items()})
    return {"trigger": t, "action": {"type": action}}


def frame_matches(pattern_list, frame_url):
    return any(re.search(p, frame_url) for p in pattern_list)


class FrameScopedRulesTests(unittest.TestCase):

    def test_pattern_matches_frame_host_and_subdomains_only(self):
        p = bf.frame_url_pattern("*kodik.info")
        self.assertEqual(p, r"^[^:]+://+([^:/]+\.)?kodik\.info([/:?#].*)?$")
        self.assertTrue(re.search(p, "https://kodik.info/seria/1/abc/720p"))
        self.assertTrue(re.search(p, "https://cdn.kodik.info:8443/x"))
        self.assertTrue(re.search(p, "https://kodik.info"))
        self.assertFalse(re.search(p, "https://kodik.info.evil.com/"))
        self.assertFalse(re.search(p, "https://notkodik.info/"))
        self.assertFalse(re.search(p, "https://kinogo.online/?u=kodik.info/"))
        exact = bf.frame_url_pattern("kodik.info")
        self.assertTrue(re.search(exact, "https://kodik.info/x"))
        self.assertFalse(re.search(exact, "https://cdn.kodik.info/x"))
        # WebKit не умеет `|` в регулярках — в шаблоне его быть не должно.
        self.assertNotIn("|", p)

    def test_unusual_domains_are_skipped(self):
        self.assertIsNone(bf.frame_url_pattern("*a_b.com"))
        self.assertIsNone(bf.frame_url_pattern("*localhost"))
        self.assertIsNotNone(bf.frame_url_pattern("*xn--80ak6aa92e.com"))

    def test_network_rules_get_frame_copy_right_after_original(self):
        rules = [
            rule(r"\.php\?id=", resource_type=["fetch"], load_type=["third-party"], if_domain=["*kodik.info", "*kodik.cc"]),
            rule(".*", "css-display-none", if_domain=["*kodik.info"]),
            rule(r"^[^:]+://+([^:/]+\.)?ads\.example[/:]", "ignore-previous-rules", if_domain=["*kodik.info"]),
            rule("x", unless_domain=["*kinogo.online"]),
            rule("y"),
        ]
        out, added = bf.add_frame_scoped(rules)
        self.assertEqual(added, 2)
        self.assertEqual(len(out), 7)
        self.assertIs(out[0], rules[0])
        copy = out[1]
        self.assertNotIn("if-domain", copy["trigger"])
        self.assertEqual(copy["trigger"]["resource-type"], ["fetch"])
        self.assertEqual(copy["trigger"]["load-type"], ["third-party"])
        self.assertTrue(frame_matches(copy["trigger"]["if-frame-url"], "https://kodik.cc/serial/1"))
        self.assertEqual(out[2]["action"]["type"], "css-display-none", "косметика не копируется")
        self.assertEqual(out[4]["action"]["type"], "ignore-previous-rules")
        self.assertIn("if-frame-url", out[4]["trigger"], "исключения копируются тоже (иначе их не отменить)")
        self.assertEqual(out[5], rules[3], "unless-domain не трогаем")
        self.assertEqual(out[6], rules[4])

    def test_rule_with_one_bad_domain_is_not_copied(self):
        out, added = bf.add_frame_scoped([rule("x", if_domain=["*ok.com", "*bad_domain.com"])])
        self.assertEqual(added, 0)
        self.assertEqual(len(out), 1)


def fake_library():
    """Мини-библиотека в формате scriptlets.corelibs.json (Library требует ≥ 20 скриптлетов)."""
    scriptlets = [{"names": ["json-prune", "ubo-json-prune.js", "json-prune.js"],
                   "scriptlet": "function jsonPrune(source, args){window.__kp=(window.__kp||[]).concat([args.join('|')]);}"},
                  {"names": ["set-constant", "ubo-set-constant.js", "set.js", "ubo-set.js"],
                   "scriptlet": "function setConstant(source, args){window[args[0]]=args[1];}"},
                  {"names": ["trusted-replace-argument"],
                   "scriptlet": "function trustedReplaceArgument(source, args){}"}]
    for i in range(20):
        scriptlets.append({"names": [f"dummy-{i}"], "scriptlet": f"function d{i}(source, args){{}}"})
    return adg.Library(json.dumps({"version": "2.6.0", "scriptlets": scriptlets}))


class FrameScriptletsTests(unittest.TestCase):

    def test_ubo_args_split_with_escaped_commas(self):
        r = adg.parse_ubo_line(r"lumex.space,~m.lumex.space##+js(json-prune-fetch-response, ads.rolls ads.banners, a\,b)")
        self.assertEqual(r["d"], ["lumex.space"])
        self.assertEqual(r["n"], ["m.lumex.space"])
        self.assertEqual(r["a"], ["json-prune-fetch-response", "ads.rolls ads.banners", "a,b"])
        self.assertFalse(r["ex"])
        ex = adg.parse_ubo_line("account.mail.ru#@#+js()")
        self.assertTrue(ex["ex"])
        self.assertEqual(ex["a"], [""])
        self.assertIsNone(adg.parse_ubo_line("example.com##.banner"))
        self.assertIsNone(adg.parse_ubo_line("/regex/##+js(set, a, 1)"))

    def test_extract_frames_skips_youtube_and_generic(self):
        text = "\n".join([
            "kodik.info,ashdi.vip##+js(json-prune, vast)",
            "youtube.com##+js(set, ytInitialPlayerResponse.adPlacements, undefined)",
            "##+js(set, genericAd, 0)",
            "!#if env_firefox",
            "firefox.only##+js(set, a, 1)",
            "!#endif",
        ])
        rules = adg.extract(text, "ubo", scope=adg.frame_scope)
        self.assertEqual(len(rules), 1)
        self.assertEqual(rules[0]["d"], ["kodik.info", "ashdi.vip"])
        ag = adg.extract("cinemar.cc,player.kinoton.cc#%#//scriptlet('trusted-replace-argument', 'String.prototype.indexOf', '0', '\"none\"', 'VAST')",
                         "adguard", scope=adg.frame_scope)
        self.assertEqual(ag[0]["a"][0], "trusted-replace-argument")

    def test_build_frames_trust_exceptions_and_host_check(self):
        lib = fake_library()
        sources = [
            ({"id": "ruadlist", "syntax": "ubo", "trusted": False},
             "kodik.info,mail.ru##+js(json-prune, vast)\nmail.ru#@#+js()\nx.ru##+js(trusted-replace-argument, a, b)"),
            ({"id": "kentik", "syntax": "adguard", "trusted": True},
             "kentik-player.test#%#//scriptlet('json-prune', 'vast adv preroll')\nplayer.test#%#window.__kj=1;"),
        ]
        frames = adg.build_frames(sources, lib)
        self.assertEqual(frames["untrusted"], 1, "trusted-скриптлет из RU AdList выброшен")
        self.assertIn("kodik.info", frames["hosts"])
        self.assertIn("kentik-player.test", frames["hosts"])
        kinds = [s["kind"] for s in frames["scripts"]]
        self.assertEqual(kinds, ["scriptlets", "js"])
        source = frames["scripts"][0]["source"]
        self.assertIn('"n":["mail.ru"]', source, "исключение #@#+js() — «не на этом сайте»")
        self.assertNotIn("function d0", source, "в скрипт идут только нужные функции библиотеки")

        node = shutil.which("node")
        if not node:
            self.skipTest("нет node — проверку в движке JS пропускаю")
        # Скрипт выполняется в «фрейме» с нужным хостом и только там.
        for host, expect in [("cdn.kodik.info", ["vast"]), ("kinogo.online", []), ("mail.ru", []),
                             ("kentik-player.test", ["vast adv preroll"])]:
            harness = ("var window=globalThis;var location={hostname:%s,pathname:'/',search:''};" % json.dumps(host)
                       + source + ";console.log(JSON.stringify(window.__kp||[]));")
            with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as f:
                f.write(harness)
                path = f.name
            try:
                out = subprocess.run([node, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            finally:
                os.unlink(path)
            self.assertEqual(json.loads(out.stdout.decode().strip()), expect, host)


if __name__ == "__main__":
    unittest.main()
