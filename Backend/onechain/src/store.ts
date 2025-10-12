import { promises as fs } from 'node:fs';
import { dirname } from 'node:path';

const DB_PATH = '/app/data/store.json';

type AidInfo = { name: string; prefix: string; transferable?: boolean };
type CredInfo = { said?: string; type: 'vlei' | 'eth'; issuer: string; holder: string; subject: any; time: string };

type Db = {
  aids: Record<string, AidInfo>;
  creds: CredInfo[];
};

async function ensureFile() {
  try { await fs.mkdir(dirname(DB_PATH), { recursive: true }); } catch {}
  try { await fs.access(DB_PATH); } catch { await fs.writeFile(DB_PATH, JSON.stringify({ aids: {}, creds: [] } as Db, null, 2)); }
}

async function readDb(): Promise<Db> {
  await ensureFile();
  const buf = await fs.readFile(DB_PATH, 'utf8');
  try { return JSON.parse(buf) as Db; } catch { return { aids: {}, creds: [] }; }
}

async function writeDb(db: Db) {
  await ensureFile();
  await fs.writeFile(DB_PATH, JSON.stringify(db, null, 2));
}

export async function putAid(info: AidInfo) {
  const db = await readDb();
  db.aids[info.name] = info;
  await writeDb(db);
}

export async function getAidLocal(name: string): Promise<AidInfo | undefined> {
  const db = await readDb();
  return db.aids[name];
}

export async function addCredential(rec: CredInfo) {
  const db = await readDb();
  db.creds.push(rec);
  await writeDb(db);
}

export async function getCredsForName(name: string): Promise<CredInfo[]> {
    const db = await readDb();
    return db.creds.filter(c => c.issuer === name || c.holder === name);
  }