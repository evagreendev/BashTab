import { readdirSync, readFileSync, writeFileSync, statSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      await walk(full);
    } else if (entry.name.endsWith('.js') && !entry.name.startsWith('-')) {
      const jsonPath = full.replace(/\.js$/, '.json');
      try {
        // Skip if JSON is newer than JS
        try {
          if (statSync(jsonPath).mtime > statSync(full).mtime) continue;
        } catch {}
        const mod = await import(full);
        const spec = mod.default || mod;
        // Drop generator functions and other non-serializable properties
        const clean = JSON.parse(JSON.stringify(spec));
        writeFileSync(jsonPath, JSON.stringify(clean));
        console.log(jsonPath);
      } catch (e) {
        // Skip files that fail (e.g. missing dependencies, browser APIs)
      }
    }
  }
}

walk(join(__dirname, 'build'));
