import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

// ============================================================
// CONFIGURE THESE VALUES FOR YOUR PROJECT
// ============================================================
const PROJECT_TITLE = 'binnacle';
const PROJECT_TAGLINE =
  'StumpCloud fleet monitor: sites → hosts → VMs → containers with hardware metrics';
// Canonical source of truth. binnacle lives on Gitea; the GitHub copy is a
// read-only push mirror.
const GITEA_URL = 'https://gitea.stump.rocks/stump.wtf/binnacle';
// Host this build is served from. binnacle publishes to Gitea Pages only —
// there is no GitHub Pages twin — so the default is the Garage-backed
// stump-wtf Pages host. CI can override it via DOCS_URL.
//
// `||`, not `??`: the shared stump.wtf/ci static-site workflow exports
// DOCS_URL as an empty string when its site_url input is unset, and an empty
// `url` fails the Docusaurus build.
const SITE_URL = process.env.DOCS_URL || 'https://stump-wtf.pages.stump.rocks';
// Path prefix. Garage-backed Gitea Pages serves under the repo name:
// https://stump-wtf.pages.stump.rocks/binnacle/
const BASE_URL = process.env.DOCS_BASE_URL || '/binnacle/';
// ============================================================

const config: Config = {
  title: PROJECT_TITLE,
  tagline: PROJECT_TAGLINE,
  favicon: 'img/favicon.svg',

  // v4 opts into the Docusaurus Faster (rspack/swc) bundler, which is why
  // @docusaurus/faster is a hard dependency rather than an optional speed-up.
  future: {
    v4: true,
  },

  url: SITE_URL,
  baseUrl: BASE_URL,

  onBrokenLinks: 'warn',

  markdown: {
    format: 'detect',
    // ADR-0001, ADR-0002 and the fleet-taxonomy design doc all carry mermaid
    // diagrams — keep this on.
    mermaid: true,
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  themes: ['@docusaurus/theme-mermaid'],

  plugins: [
    ['./plugins/sdd-content', {
      adrsDir: '../docs/adrs',
      specsDir: '../docs/specs',
      outputDir: '../docs-generated',
    }],
  ],

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          path: '../docs-generated',
          sidebarPath: './sidebars.ts',
          routeBasePath: '/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    colorMode: {
      defaultMode: 'dark',
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: PROJECT_TITLE,
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'decisionsSidebar',
          position: 'left',
          label: 'ADRs',
        },
        {
          type: 'docSidebar',
          sidebarId: 'specsSidebar',
          position: 'left',
          label: 'Specifications',
        },
        {
          to: '/graph',
          position: 'left',
          label: 'Graph',
        },
        {
          href: GITEA_URL,
          label: 'Gitea',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Documentation',
          items: [
            {
              label: 'Architecture Decisions',
              to: '/decisions',
            },
            {
              label: 'Specifications',
              to: '/specs',
            },
            {
              label: 'Architecture Graph',
              to: '/graph',
            },
          ],
        },
        {
          title: 'Project',
          items: [
            {
              label: 'Gitea',
              href: GITEA_URL,
            },
          ],
        },
      ],
      copyright: `Copyright ${new Date().getFullYear()}. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['json', 'bash'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
