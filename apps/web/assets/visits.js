// Counts visits to this site with PostHog: one pageview per page load and clicks on links that
// leave the site. No cookies, no browser storage, no person profiles and no recording; each page
// load gets a fresh random id that is never saved. Nothing is sent on any other host (forks and
// local copies stay silent) or when the browser asks not to be tracked (Do Not Track or Global
// Privacy Control). The project key is PostHog's public, write-only client key.
(() => {
  'use strict';
  const site = 'mercurius.mykoala.com.au';
  const endpoint = 'https://us.i.posthog.com/i/v0/e/';
  const projectKey = 'phc_mozUWhWYvBp3AMgdpYunaxYfXUdRAQMuGRfe4mU5qmbH';
  if (location.hostname !== site) return;
  if (navigator.globalPrivacyControl === true || navigator.doNotTrack === '1' || window.doNotTrack === '1') return;
  const visit = typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID()
    : Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, '0')).join('');
  const campaign = {};
  const query = new URLSearchParams(location.search);
  for (const name of ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term']) {
    const value = query.get(name);
    if (value) campaign[name] = value.slice(0, 100);
  }
  let referrer = '$direct';
  let referringDomain = '$direct';
  try {
    if (document.referrer) {
      const from = new URL(document.referrer);
      referrer = from.origin;
      referringDomain = from.host;
    }
  } catch (error) {
    // An unreadable referrer counts as direct.
  }
  const send = (event, extra) => {
    const body = JSON.stringify({
      api_key: projectKey,
      event,
      distinct_id: visit,
      timestamp: new Date().toISOString(),
      properties: Object.assign({
        $process_person_profile: false,
        $lib: 'mercurius-web',
        $host: site,
        $pathname: location.pathname,
        $current_url: 'https://' + site + location.pathname,
        $referrer: referrer,
        $referring_domain: referringDomain
      }, campaign, extra)
    });
    try {
      fetch(endpoint, {
        method: 'POST', body, keepalive: true, mode: 'cors', credentials: 'omit', referrerPolicy: 'no-referrer',
        headers: { 'Content-Type': 'text/plain' }
      }).catch(() => {});
    } catch (error) {
      // Counting must never break the page.
    }
  };
  send('$pageview', {});
  document.addEventListener('click', (event) => {
    const link = event.target instanceof Element ? event.target.closest('a[href]') : null;
    if (!link) return;
    let target;
    try { target = new URL(link.href); } catch (error) { return; }
    if (target.host === site || !/^https?:$/.test(target.protocol)) return;
    send('outbound_link_clicked', { link_host: target.host, link_path: target.pathname });
  }, { capture: true, passive: true });
})();
