import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';
import tailwindcss from '@tailwindcss/vite';

const site = 'https://nogipx.github.io/rpc_dart/';
const locales = {
	root: { label: 'English', lang: 'en' },
	ru: { label: 'Русский', lang: 'ru' },
};

// Отключаем валидацию ссылок в CI окружении
const isCI = process.env.CI === 'true' || process.env.DISABLE_LINK_VALIDATION === 'true';
const linkValidatorConfig = isCI 
	? { 
		errorOnFallbackPages: false, 
		errorOnInconsistentLocale: false,
		errorOnRelativeLinks: false,
		errorOnInvalidHashes: false,
		exclude: ['**'] // Отключить все проверки в CI
	}
	: { 
		errorOnFallbackPages: false, 
		errorOnInconsistentLocale: false,
		errorOnRelativeLinks: false,
		exclude: ['**/reference/**']
	};

// https://astro.build/config
export default defineConfig({
	site,
	integrations: [
		starlight({
			expressiveCode: { 
				themes: ['nord', 'min-light'],
				defaultProps: {
					// Enable word wrap by default
					wrap: true,
					// Show line numbers
					showLineNumbers: true,
				}
			},
			title: 'RPC Dart',
			editLink: { baseUrl: 'https://github.com/nogipx/rpc_dart/edit/main/docs/' },
			tagline: 'Pure Dart RPC library for type-safe communication',
			favicon: 'favicon.ico',
			head: [
				{ tag: 'meta', attrs: { property: 'og:image', content: site + 'og.png?v=1' } },
				{ tag: 'meta', attrs: { property: 'twitter:image', content: site + 'og.png?v=1' } },
			],
			customCss: [
				'src/tailwind.css', 
				'src/styles/landing.css', 
				'src/styles/custom.css',
				'@fontsource-variable/figtree'
			],
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/nogipx/rpc_dart' },
			],
			defaultLocale: 'root',
			locales,
			sidebar: [
				{
					label: 'Introduction',
					translations: { ru: 'Введение' },
					items: [
						{
							label: 'Getting Started',
							link: '/getting-started/',
							translations: { ru: 'Быстрый старт' },
						},
						{
							label: 'Core Concepts',
							link: '/core-concepts/',
							translations: { ru: 'Основные концепции' },
						},
						{
							label: 'Architecture',
							link: '/architecture/',
							translations: { ru: 'Архитектура' },
						},
					],
				},
				{
					label: 'Transports',
					translations: { ru: 'Транспорты' },
					items: [
						{
							label: 'InMemory Transport',
							link: '/transports/inmemory/',
							translations: { ru: 'InMemory Транспорт' },
						},
            {
							label: 'HTTP/2 Transport',
							link: '/transports/http2/',
							translations: { ru: 'HTTP/2 Транспорт' },
						},
            {
							label: 'Isolate Transport',
							link: '/transports/isolate/',
							translations: { ru: 'Isolate Транспорт' },
						},
            {
							label: 'WebSocket Transport',
							link: '/transports/websocket/',
							translations: { ru: 'WebSocket Транспорт' },
						},
						{
              label: 'Custom Transport Toolkit',
              link: '/transports/transport-toolkit/',
              translations: { ru: 'Иструментарий для создания транспортов' },
            },
					],
				},
				// {
				// 	label: 'Tutorials',
				// 	translations: { ru: 'Туториалы' },
				// 	autogenerate: { directory: 'tutorials' },
				// },
				{
					label: 'Reference',
					translations: { ru: 'Справочник' },
					items: [
						{
							label: 'rpc_dart',
              items: [
                {
                  label: 'pub.dev',
                  link: 'https://pub.dev/packages/rpc_dart',
                },
                {
                  label: 'API',
                  link: 'https://pub.dev/documentation/rpc_dart/latest/index.html',
                },
                { 
                  label: 'DeepWiki', 
                  link: 'https://deepwiki.com/nogipx/rpc_dart'
                },
                { 
                  label: 'context7', 
                  link: 'https://context7.com/nogipx/rpc_dart'
                },
              ],
						},
						{
							label: 'rpc_dart_transports',
              items: [
                {
                  label: 'pub.dev',
                  link: 'https://pub.dev/packages/rpc_dart_transports',
                },
                {
                  label: 'API',
                  link: 'https://pub.dev/documentation/rpc_dart_transports/latest/index.html',
                },
              ],
						},
					],
				},
			],
			plugins: [
				starlightLinksValidator(linkValidatorConfig),
			],
		}),
	],
	vite: { plugins: [tailwindcss()] },
});
