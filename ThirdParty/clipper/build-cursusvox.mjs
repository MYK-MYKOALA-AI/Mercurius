// Bundles src/cursusvox.ts into one browser script for the CursusVox app (fork addition).
import * as esbuild from 'esbuild';
// The extension's browser-API wrapper refuses to load outside an extension; the clip
// pipeline never calls it, so it is replaced with an empty object here.
const stubPolyfill = {
	name: 'stub-webextension-polyfill',
	setup(build) {
		build.onResolve({ filter: /^webextension-polyfill$/ }, () => ({ path: 'stub', namespace: 'stub' }));
		build.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({ contents: 'module.exports = {};', loader: 'js' }));
	},
};
await esbuild.build({
	entryPoints: ['src/cursusvox.ts'], bundle: true, format: 'iife', platform: 'browser', target: 'safari17',
	minify: true, outfile: 'dist-cursusvox/cursus-clip.js', legalComments: 'eof',
	plugins: [stubPolyfill],
	define: { 'process.env.NODE_ENV': '"production"', DEBUG_MODE: 'false' },
});
console.log('built dist-cursusvox/cursus-clip.js');
