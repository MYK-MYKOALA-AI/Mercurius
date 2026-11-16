// CursusVox entry (fork addition, not upstream): runs the clipper's page-to-Markdown
// pipeline inside a hidden web view in the CursusVox app, using the browser's own
// DOMParser. The app passes the page HTML and URL; it gets back the note name and
// the full note (frontmatter + Markdown). Nothing here touches the network.
import { clip } from './api';
import type { Template } from './types/types';

const template: Template = {
	id: 'cursusvox',
	name: 'CursusVox clip',
	behavior: 'create',
	path: '',
	noteNameFormat: '{{title}}',
	noteContentFormat: '{{content}}',
	properties: [
		{ name: 'title', value: '{{title}}', type: 'text' },
		{ name: 'source', value: '{{url}}', type: 'text' },
		{ name: 'author', value: '{{author}}', type: 'text' },
		{ name: 'published', value: '{{published}}', type: 'date' },
		{ name: 'site', value: '{{site}}', type: 'text' },
		{ name: 'description', value: '{{description}}', type: 'text' },
		{ name: 'clipped', value: '{{date}}', type: 'datetime' },
		{ name: 'tags', value: 'clippings', type: 'multitext' },
	],
};

async function clipPage(html: string, url: string): Promise<string> {
	const result = await clip({ html, url, template, documentParser: new DOMParser() });
	return JSON.stringify({ noteName: result.noteName, note: result.fullContent, title: result.variables['{{title}}'] ?? result.variables.title ?? result.noteName });
}

(globalThis as any).CursusClip = clipPage;
