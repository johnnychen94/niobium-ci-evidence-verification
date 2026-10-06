import { defineCollection } from 'astro:content';
import { z } from 'astro/zod';
import { docsLoader, i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';

const siteStrings = z.object({
  'niobium.locale.label': z.string(),
  'niobium.sidebar.startHere': z.string(),
  'niobium.sidebar.overview': z.string(),
  'niobium.sidebar.tutorial': z.string(),
  'niobium.sidebar.concepts': z.string(),
  'niobium.sidebar.guides': z.string(),
  'niobium.sidebar.reference': z.string(),
  'niobium.version.label': z.string(),
  'niobium.version.next': z.string(),
  'niobium.version.latest': z.string(),
  'niobium.version.latestSuffix': z.string(),
  'niobium.banner.next': z.string(),
  'niobium.banner.old': z.string(),
  'niobium.banner.toLatest': z.string(),
});

export const collections = {
  docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
  i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema({ extend: siteStrings }) }),
};
