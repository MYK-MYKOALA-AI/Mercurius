"""Check the static website's privacy promises: the visit counter, its CSP and its cache tags."""
from pathlib import Path
import hashlib
import json
import os
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
const origin = scenario.origin || 'https://' + scenario.host;
const crypto = { getRandomValues: (a) => a.fill(7) };
if (!scenario.noUUID) crypto.randomUUID = () => 'id-' + Math.random();
const context = {
  location: { hostname: scenario.host, origin, pathname: scenario.path || '/', search: scenario.search || '' },
  navigator: { doNotTrack: scenario.dnt, msDoNotTrack: scenario.msDnt, globalPrivacyControl: scenario.gpc },
  document, window, Element, URL, URLSearchParams, JSON, Date, Array, Uint8Array, Object,
  crypto: scenario.noCrypto ? undefined : crypto,
  fetch: scenario.noFetch ? undefined : (url, init) => { sent.push({ url, init: { ...init, body: JSON.parse(init.body) } }); return Promise.resolve(); },
};
for (const name of ['localStorage', 'sessionStorage', 'indexedDB']) Object.defineProperty(context, name, guard(name));
for (const name of ['localStorage', 'sessionStorage', 'indexedDB']) Object.defineProperty(window, name, guard('window.' + name));
vm.runInNewContext(source, context);
for (const href of scenario.clicks || []) listeners.click && listeners.click({ target: new Element(href) });
console.log(JSON.stringify({ sent, touched }));
"""


def run(**scenario):
    result = subprocess.run(['node', '-e', HARNESS, COUNTER.read_text(), json.dumps(scenario)],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


@unittest.skipUnless(shutil.which('node') or os.environ.get('CI'), 'node is needed to run the visit counter')
class VisitCounter(unittest.TestCase):
    def test_silent_off_the_site_and_when_asked_not_to_track(self):
        for scenario in [dict(host='localhost'), dict(host='example.github.io'), dict(host=SITE + '.evil.test'),
                         dict(host=SITE, origin=f'http://{SITE}:8080'), dict(host=SITE, origin=f'http://{SITE}'),
                         dict(host=SITE, dnt='1'), dict(host=SITE, dnt='yes'), dict(host=SITE, windowDnt='1'),
                         dict(host=SITE, msDnt='1'), dict(host=SITE, gpc=True),
                         dict(host=SITE, noFetch=True), dict(host=SITE, noCrypto=True)]:
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
        self.assertEqual((props['$referrer'], props['$referring_domain']), ('other', 'other'))
        self.assertEqual(props['utm_source'], 'newsletter')
        self.assertNotIn('someone', json.dumps(body))
        self.assertEqual(request['init']['referrerPolicy'], 'no-referrer')
        self.assertTrue(request['init']['keepalive'])

    def test_never_sends_what_a_visitor_typed(self):
        result = run(host=SITE, path='/invite/someone@example.com',
                     search='?utm_source=someone%40example.com&utm_medium=email&utm_campaign=Jane.Doe'
                            '&utm_content=someone%40example.com&utm_term=secret')
        body = result['sent'][0]['init']['body']
        for private in ['someone', 'Jane', 'secret']:
            self.assertNotIn(private, json.dumps(body))
        self.assertEqual(body['properties']['$pathname'], '/other')
        self.assertEqual(body['properties']['$current_url'], f'https://{SITE}/other')
        self.assertEqual(body['properties']['utm_source'], 'other')
        self.assertEqual(body['properties']['utm_medium'], 'email')
        for name in ['utm_campaign', 'utm_content', 'utm_term']:
            self.assertNotIn(name, body['properties'])

    def test_campaign_tags_are_known_labels_or_other(self):
        for source, medium, expected in [('LinkedIn', 'Social', ('linkedin', 'social')),
                                         ('Jane.Doe', 'customer-12345', ('other', 'other')),
                                         ('0400000000', 'email', ('other', 'email'))]:
            with self.subTest(source=source):
                props = run(host=SITE, search=f'?utm_source={source}&utm_medium={medium}&utm_campaign=Jane.Doe'
                            )['sent'][0]['init']['body']['properties']
                self.assertEqual((props['utm_source'], props['utm_medium']), expected)
                self.assertNotIn('utm_campaign', props)

    def test_only_known_referring_sites_are_named(self):
        for referrer, expected in [('https://www.google.com.au/', 'google'), ('https://www.linkedin.com/feed/', 'linkedin.com'),
                                   ('https://t.co/abc', 't.co'), ('https://jane-doe.portal.example/inbox', 'other'),
                                   ('https://customer-12345.example.com/', 'other'), ('https://google.evil.example/', 'other')]:
            with self.subTest(referrer=referrer):
                props = run(host=SITE, referrer=referrer)['sent'][0]['init']['body']['properties']
                self.assertEqual((props['$referrer'], props['$referring_domain']), (expected, expected))

    def test_only_website_referrers_count(self):
        for referrer in ['android-app://com.example.mail/', 'chrome-extension://abcdefghijklmnop/popup.html',
                         'file:///tmp/page.html', 'about:blank', 'not a url']:
            with self.subTest(referrer=referrer):
                props = run(host=SITE, referrer=referrer)['sent'][0]['init']['body']['properties']
                self.assertEqual((props['$referrer'], props['$referring_domain']), ('$direct', '$direct'))

    def test_falls_back_when_random_uuid_is_missing(self):
        result = run(host=SITE, noUUID=True)
        self.assertEqual(len(result['sent']), 1)
        self.assertRegex(result['sent'][0]['init']['body']['distinct_id'], r'^[0-9a-f]{32}$')

    def test_counts_only_links_that_leave_the_site(self):
        result = run(host=SITE, clicks=[f'https://{SITE}/#install', 'mailto:a@example.com',
                                        'https://github.com/SHAMALKRISHNA/Mercurius?tab=readme'])
        events = [request['init']['body'] for request in result['sent']]
        self.assertEqual([event['event'] for event in events], ['$pageview', 'outbound_link_clicked'])
        self.assertEqual(events[1]['properties']['link_host'], 'github.com')
        self.assertNotIn('link_path', events[1]['properties'])
        self.assertNotIn('SHAMALKRISHNA', json.dumps(events[1]))
        self.assertEqual(events[0]['distinct_id'], events[1]['distinct_id'])


class SitePages(unittest.TestCase):
    def test_csp_allows_only_self_hosted_scripts_and_posthog(self):
        headers = (WEB / '_headers').read_text()
        csp = re.search(r'Content-Security-Policy: (.+)', headers).group(1)
        directives = dict(part.strip().split(' ', 1) for part in csp.split(';') if part.strip())
        self.assertEqual(directives['default-src'], "'none'")
        self.assertEqual(directives['frame-ancestors'], "'none'")
        self.assertEqual(directives['script-src'], "'self'")
        self.assertEqual(directives['connect-src'], 'https://us.i.posthog.com/i/v0/e/')
        self.assertNotIn('unsafe', csp)

    def test_every_page_loads_only_hashed_self_hosted_files(self):
        expected = {'index.html': ['assets/visits.js', 'styles.css'], '404.html': ['styles.css']}
        self.assertEqual(sorted(p.relative_to(WEB).as_posix() for p in WEB.glob('**/*.html')), sorted(expected))
        for page, files in expected.items():
            html = (WEB / page).read_text()
            with self.subTest(page=page):
                for tag in re.findall(r'<script\b[^>]*>', html):
                    self.assertRegex(tag, r'^<script src="/?assets/visits\.js\?v=[0-9a-f]{8}" defer>$')
                self.assertNotRegex(html, r'(?:src|href)="(?:https?:)?//[^"]*\.(?:js|css)')
                prefix = '/' if page == '404.html' else '/?'
                refs = re.findall(r'(?:src|href)="' + prefix + r'((?:assets/visits\.js|styles\.css))\?v=([0-9a-f]{8})"', html)
                self.assertEqual(sorted(name for name, _ in refs), files)
                for name, tag in refs:
                    self.assertEqual(hashlib.sha256((WEB / name).read_bytes()).hexdigest()[:8], tag, name)

    def test_only_pages_that_say_so_count_visits(self):
        for path in WEB.glob('**/*.html'):
            html = path.read_text()
            with self.subTest(page=path.name):
                if 'visits.js' in html:
                    self.assertIn('counts visits and clicks on links to other sites with PostHog', html)
        self.assertNotIn('visits.js', (WEB / '404.html').read_text())

    def test_the_page_says_it_counts_visits(self):
        html = (WEB / 'index.html').read_text()
        self.assertIn('This page counts visits and clicks on links to other sites with PostHog', html)


if __name__ == '__main__':
    unittest.main()
