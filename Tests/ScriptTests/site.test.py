"""Check the static website's privacy promises: the visit counter, its CSP and its cache tags."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import unittest

WEB = Path(__file__).resolve().parents[2] / 'apps/web'
COUNTER = WEB / 'assets/visits.js'
SITE = 'mercurius.mykoala.com.au'

# Runs visits.js against fake browser globals and prints what it sent and touched as JSON.
HARNESS = r"""
const vm = require('vm');
const [source, scenario] = [process.argv[1], JSON.parse(process.argv[2])];
const sent = [];
const touched = [];
const listeners = {};
class Element { constructor(href) { this.href = href; } closest() { return this.href ? this : null; } }
const guard = (name) => ({ get() { touched.push(name); return undefined; }, set() { touched.push(name); } });
const document = { referrer: scenario.referrer || '', addEventListener: (type, fn) => { listeners[type] = fn; } };
Object.defineProperty(document, 'cookie', guard('document.cookie'));
const window = { doNotTrack: scenario.windowDnt };
const context = {
  location: { hostname: scenario.host, pathname: '/', search: scenario.search || '' },
  navigator: { doNotTrack: scenario.dnt, globalPrivacyControl: scenario.gpc },
  document, window, Element, URL, URLSearchParams, JSON, Date, Array, Uint8Array, Object,
  crypto: { randomUUID: () => 'id-' + Math.random(), getRandomValues: (a) => a },
  fetch: (url, init) => { sent.push({ url, init: { ...init, body: JSON.parse(init.body) } }); return Promise.resolve(); },
};
for (const name of ['localStorage', 'sessionStorage', 'indexedDB']) Object.defineProperty(context, name, guard(name));
Object.defineProperty(window, 'localStorage', guard('window.localStorage'));
vm.runInNewContext(source, context);
for (const href of scenario.clicks || []) listeners.click && listeners.click({ target: new Element(href) });
console.log(JSON.stringify({ sent, touched }));
"""


def run(**scenario):
    result = subprocess.run(['node', '-e', HARNESS, COUNTER.read_text(), json.dumps(scenario)],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


@unittest.skipUnless(shutil.which('node'), 'node is needed to run the visit counter')
class VisitCounter(unittest.TestCase):
    def test_silent_off_the_site_and_when_asked_not_to_track(self):
        for scenario in [dict(host='localhost'), dict(host='example.github.io'), dict(host=SITE + '.evil.test'),
                         dict(host=SITE, dnt='1'), dict(host=SITE, windowDnt='1'), dict(host=SITE, gpc=True)]:
            with self.subTest(**scenario):
                result = run(clicks=['https://github.com/x'], **scenario)
                self.assertEqual(result['sent'], [])
                self.assertEqual(result['touched'], [])

    def test_counts_a_visit_without_cookies_storage_or_a_person(self):
        result = run(host=SITE, search='?utm_source=newsletter&email=someone%40example.com',
                     referrer='https://news.example/item?id=7#top')
        self.assertEqual(result['touched'], [])
        self.assertEqual(len(result['sent']), 1)
        request = result['sent'][0]
        self.assertEqual(request['url'], 'https://us.i.posthog.com/i/v0/e/')
        self.assertEqual(request['init']['credentials'], 'omit')
        body = request['init']['body']
        self.assertRegex(body['api_key'], r'^phc_[A-Za-z0-9]+$')
        self.assertEqual(body['event'], '$pageview')
        props = body['properties']
        self.assertIs(props['$process_person_profile'], False)
        self.assertEqual(props['$current_url'], f'https://{SITE}/')
        self.assertEqual(props['$referrer'], 'https://news.example')
        self.assertEqual(props['utm_source'], 'newsletter')
        self.assertNotIn('someone', json.dumps(body))

    def test_counts_only_links_that_leave_the_site(self):
        result = run(host=SITE, clicks=[f'https://{SITE}/#install', 'mailto:a@example.com',
                                        'https://github.com/SHAMALKRISHNA/Mercurius?tab=readme'])
        events = [request['init']['body'] for request in result['sent']]
        self.assertEqual([event['event'] for event in events], ['$pageview', 'outbound_link_clicked'])
        self.assertEqual(events[1]['properties']['link_host'], 'github.com')
        self.assertEqual(events[1]['properties']['link_path'], '/SHAMALKRISHNA/Mercurius')
        self.assertEqual(events[0]['distinct_id'], events[1]['distinct_id'])


class SitePages(unittest.TestCase):
    def test_csp_allows_only_self_hosted_scripts_and_posthog(self):
        headers = (WEB / '_headers').read_text()
        csp = re.search(r'Content-Security-Policy: (.+)', headers).group(1)
        directives = dict(part.strip().split(' ', 1) for part in csp.split(';') if part.strip())
        self.assertEqual(directives['script-src'], "'self'")
        self.assertEqual(directives['connect-src'], 'https://us.i.posthog.com')
        self.assertNotIn('unsafe', csp)

    def test_every_page_loads_only_hashed_self_hosted_files(self):
        for page in ['index.html', '404.html']:
            html = (WEB / page).read_text()
            with self.subTest(page=page):
                self.assertNotIn('<script>', html)
                refs = re.findall(r'(?:src|href)="/?((?:assets/visits\.js|styles\.css))\?v=([0-9a-f]{8})"', html)
                self.assertEqual(sorted(name for name, _ in refs), ['assets/visits.js', 'styles.css'])
                for name, tag in refs:
                    self.assertEqual(hashlib.sha256((WEB / name).read_bytes()).hexdigest()[:8], tag, name)
                self.assertNotRegex(html, r'<script[^>]+src="https?:')

    def test_the_page_says_it_counts_visits(self):
        html = (WEB / 'index.html').read_text()
        self.assertIn('This site counts visits with PostHog', html)


if __name__ == '__main__':
    unittest.main()
