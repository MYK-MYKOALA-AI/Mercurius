# Third-party software notices

The bundled `Resources/cursus-clip.js` uses the Obsidian Web Clipper page-to-Markdown pipeline. Upstream [Obsidian Web Clipper](https://github.com/obsidianmd/obsidian-clipper), version 1.7.1, is MIT licensed, copyright 2024 Obsidian. Its full licence is in `ThirdParty/clipper/LICENSE`. Mercurius adds an application entry point; that adapter and its build recipe are in `ThirdParty/clipper/`. The JavaScript bundle is vendored; the normal Swift build does not install npm packages.

To rebuild the clipper, use an upstream Obsidian Web Clipper 1.7.1 source checkout, copy `ThirdParty/clipper/cursusvox.ts` into its `src/` folder, and copy `build-cursusvox.mjs`, `package.json` and `package-lock.json` into its root. Review the npm lifecycle scripts before installing the locked dependencies, then run `node build-cursusvox.mjs` from that upstream root. It writes `dist-cursusvox/cursus-clip.js`; retain the Mercurius licence-notice header when replacing the vendored bundle. This recipe needs the upstream source tree, not just this notices directory. Mercurius retains that upstream 1.7.1 source and applies the dependency security updates recorded in its package files. Install with lifecycle scripts disabled (`npm ci --ignore-scripts`); the build calls esbuild directly.

The table below conservatively includes the upstream lockfile's non-development JavaScript packages, including packages the bundler may have removed. Original licence/copyright texts are retained in `ThirdParty/clipper/licences/`. Those licences, rather than Mercurius's root MIT licence, govern third-party code. DOMPurify's published alternative licences are retained. Package metadata does not by itself replace the actual licence text.

| Package | Version | Licence text |
|---|---|---|
| @codemirror/autocomplete | 6.20.3 | [_codemirror_autocomplete-6.20.3_LICENSE](ThirdParty/clipper/licences/_codemirror_autocomplete-6.20.3_LICENSE) |
| @codemirror/commands | 6.11.0 | [_codemirror_commands-6.11.0_LICENSE](ThirdParty/clipper/licences/_codemirror_commands-6.11.0_LICENSE) |
| @codemirror/language | 6.12.4 | [_codemirror_language-6.12.4_LICENSE](ThirdParty/clipper/licences/_codemirror_language-6.12.4_LICENSE) |
| @codemirror/state | 6.7.4 | [_codemirror_state-6.7.4_LICENSE](ThirdParty/clipper/licences/_codemirror_state-6.7.4_LICENSE) |
| @codemirror/view | 6.43.11 | [_codemirror_view-6.43.11_LICENSE](ThirdParty/clipper/licences/_codemirror_view-6.43.11_LICENSE) |
| @lezer/common | 1.5.2 | [_lezer_common-1.5.2_LICENSE](ThirdParty/clipper/licences/_lezer_common-1.5.2_LICENSE) |
| @lezer/highlight | 1.2.3 | [_lezer_highlight-1.2.3_LICENSE](ThirdParty/clipper/licences/_lezer_highlight-1.2.3_LICENSE) |
| @lezer/lr | 1.4.10 | [_lezer_lr-1.4.10_LICENSE](ThirdParty/clipper/licences/_lezer_lr-1.4.10_LICENSE) |
| @marijn/find-cluster-break | 1.0.4 | [_marijn_find-cluster-break-1.0.4_LICENSE](ThirdParty/clipper/licences/_marijn_find-cluster-break-1.0.4_LICENSE) |
| @mixmark-io/domino | 2.2.0 | [_mixmark-io_domino-2.2.0_LICENSE](ThirdParty/clipper/licences/_mixmark-io_domino-2.2.0_LICENSE) |
| @xmldom/xmldom | 0.9.12 | [_xmldom_xmldom-0.9.12_LICENSE](ThirdParty/clipper/licences/_xmldom_xmldom-0.9.12_LICENSE) |
| boolbase | 1.0.0 | [boolbase-1.0.0_LICENSE](ThirdParty/clipper/licences/boolbase-1.0.0_LICENSE) |
| crelt | 1.0.7 | [crelt-1.0.7_LICENSE](ThirdParty/clipper/licences/crelt-1.0.7_LICENSE) |
| css-select | 5.2.2 | [css-select-5.2.2_LICENSE](ThirdParty/clipper/licences/css-select-5.2.2_LICENSE) |
| css-what | 6.2.2 | [css-what-6.2.2_LICENSE](ThirdParty/clipper/licences/css-what-6.2.2_LICENSE) |
| cssom | 0.5.0 | [cssom-0.5.0_LICENSE.txt](ThirdParty/clipper/licences/cssom-0.5.0_LICENSE.txt) |
| dayjs | 1.11.23 | [dayjs-1.11.23_LICENSE](ThirdParty/clipper/licences/dayjs-1.11.23_LICENSE) |
| defuddle | 0.19.2 | [defuddle-0.19.2_LICENSE](ThirdParty/clipper/licences/defuddle-0.19.2_LICENSE) |
| commander | 12.1.0 | [commander-12.1.0_LICENSE](ThirdParty/clipper/licences/commander-12.1.0_LICENSE) |
| dom-serializer | 2.0.0 | [dom-serializer-2.0.0_LICENSE](ThirdParty/clipper/licences/dom-serializer-2.0.0_LICENSE) |
| entities | 4.5.0 | [entities-4.5.0_LICENSE](ThirdParty/clipper/licences/entities-4.5.0_LICENSE) |
| domelementtype | 2.3.0 | [domelementtype-2.3.0_LICENSE](ThirdParty/clipper/licences/domelementtype-2.3.0_LICENSE) |
| domhandler | 5.0.3 | [domhandler-5.0.3_LICENSE](ThirdParty/clipper/licences/domhandler-5.0.3_LICENSE) |
| dompurify | 3.4.18 | [dompurify-3.4.18_LICENSE](ThirdParty/clipper/licences/dompurify-3.4.18_LICENSE), [dompurify-3.4.18_LICENSE-MPL](ThirdParty/clipper/licences/dompurify-3.4.18_LICENSE-MPL), [dompurify-3.4.18_src_license_header](ThirdParty/clipper/licences/dompurify-3.4.18_src_license_header) |
| domutils | 3.2.2 | [domutils-3.2.2_LICENSE](ThirdParty/clipper/licences/domutils-3.2.2_LICENSE) |
| entities | 7.0.1 | [entities-7.0.1_LICENSE](ThirdParty/clipper/licences/entities-7.0.1_LICENSE) |
| highlight.js | 11.11.1 | [highlight.js-11.11.1_LICENSE](ThirdParty/clipper/licences/highlight.js-11.11.1_LICENSE) |
| html-escaper | 3.0.3 | [html-escaper-3.0.3_LICENSE.txt](ThirdParty/clipper/licences/html-escaper-3.0.3_LICENSE.txt) |
| htmlparser2 | 10.1.0 | [htmlparser2-10.1.0_LICENSE](ThirdParty/clipper/licences/htmlparser2-10.1.0_LICENSE) |
| knap | 0.6.0 | [knap-0.6.0_LICENSE](ThirdParty/clipper/licences/knap-0.6.0_LICENSE) |
| linkedom | 0.18.12 | [linkedom-0.18.12_LICENSE](ThirdParty/clipper/licences/linkedom-0.18.12_LICENSE) |
| lucide | 0.359.0 | [lucide-0.359.0_LICENSE](ThirdParty/clipper/licences/lucide-0.359.0_LICENSE) |
| lz-string | 1.5.0 | [lz-string-1.5.0_LICENSE](ThirdParty/clipper/licences/lz-string-1.5.0_LICENSE) |
| mathml-to-latex | 1.8.0 | [mathml-to-latex-1.8.0_LICENSE.md](ThirdParty/clipper/licences/mathml-to-latex-1.8.0_LICENSE.md) |
| nth-check | 2.1.1 | [nth-check-2.1.1_LICENSE](ThirdParty/clipper/licences/nth-check-2.1.1_LICENSE) |
| style-mod | 4.1.3 | [style-mod-4.1.3_LICENSE](ThirdParty/clipper/licences/style-mod-4.1.3_LICENSE) |
| temml | 0.13.3 | [temml-0.13.3_LICENSE](ThirdParty/clipper/licences/temml-0.13.3_LICENSE) |
| turndown | 7.2.4 | [turndown-7.2.4_LICENSE](ThirdParty/clipper/licences/turndown-7.2.4_LICENSE) |
| uhyphen | 0.2.0 | [uhyphen-0.2.0_LICENSE](ThirdParty/clipper/licences/uhyphen-0.2.0_LICENSE) |
| w3c-keyname | 2.2.8 | [w3c-keyname-2.2.8_LICENSE](ThirdParty/clipper/licences/w3c-keyname-2.2.8_LICENSE) |

## Artwork and media

Original Mercurius/Koa artwork uses CC BY 4.0, with trademark rights reserved. The Met illustration is public domain. See [LICENSE-ARTWORK.md](LICENSE-ARTWORK.md). Private audio/TTS fixtures and generated Blender scene files are not included in this source snapshot.
