import React, { useState, useEffect, useCallback } from 'react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';

// ==================== TYPES ====================
interface User { name: string; role: string; createdAt?: string; }
interface DriveRecord {
  id: string; owner: string; createdAt: string; serial: string; model: string;
  firmware: string; capacityGB: number; bus: string; media: string;
  healthStatus: string; wear: number; tempC: number; readErrors: number; writeErrors: number;
  seqRead: number; seqWrite: number; rndRead: number; rndWrite: number;
  rndReadIops: number; rndWriteIops: number; batch: string; method: string;
  healthScore: number; lifePct: number; profileId: string; profileName: string;
  speedVerdict: string; verdict: string; notes: string;
  extended: {
    mix?: { readMbps: number; writeMbps: number; iops: number };
    qd?: { seqQ8R: number; seqQ8W: number; rndQ32R: number; rndQ32W: number };
    sustained?: { cacheMB: number; sustainedMbps: number; maxTemp: number; sizeMB: number; series: {s:number;mbps:number;temp:number;cum:number}[] };
    integrity?: { testedMB: number; badBlocks: number; firstBadMB: number };
  };
}
interface Profile {
  id: string; name: string; matchSubstring: string; bus: string; media: string;
  minSeqR: number; minSeqW: number; min4kR: number; min4kW: number;
  tolerancePct: number; ratedTBW: number;
}
interface Label { id: string; name: string; widthMm: number; heightMm: number; }
interface ModelFamily { id: string; family: string; manufacturer: string; matchPattern: string; }
interface LifecycleEntry {
  serial: string; status: string; updated: string; by: string; lastTest: string;
  history: { at: string; by: string; status: string; note: string }[];
}
interface ProbeDrive {
  diskNumber: number; model: string; serial: string; firmware: string;
  capacityGB: number; bus: string; media: string; healthStatus: string;
  operationalStatus: string; letters: string[]; wear: number; tempC: number;
  readErrors: number; writeErrors: number; relOk: boolean; relErr: string;
  letSrc: string; fwSrc: string;
}

// ==================== API ====================
const API_BASE = window.location.origin && window.location.origin !== 'null' 
  ? window.location.origin 
  : 'http://localhost:8080';
const PROBE_BASE = 'http://127.0.0.1:8321';

async function api(path: string, method = 'GET', body?: any, token?: string): Promise<any> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(`${API_BASE}${path}`, {
    method, headers, body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || 'Request failed');
  return data;
}

async function probe(path: string, body?: any): Promise<any> {
  try {
    const res = await fetch(`${PROBE_BASE}${path}`, {
      method: body ? 'POST' : 'GET',
      headers: { 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await res.json();
    return data;
  } catch (e) {
    console.error('[PROBE] Error calling', path, ':', e);
    throw e;
  }
}

// ==================== HELPERS ====================
function matchProfile(model: string, bus: string, media: string, profiles: Profile[]): Profile | null {
  const candidates = profiles.filter(p => {
    if (p.bus !== 'ANY' && p.bus !== bus) return false;
    if (p.media !== 'ANY' && p.media !== media) return false;
    if (p.matchSubstring && !model.toLowerCase().includes(p.matchSubstring.toLowerCase())) return false;
    return true;
  });
  if (candidates.length === 0) return null;
  return candidates.sort((a, b) => (b.matchSubstring?.length || 0) - (a.matchSubstring?.length || 0))[0];
}

function matchModelFamily(model: string, models: ModelFamily[]): ModelFamily | null {
  const candidates = models.filter(m => {
    if (!m.matchPattern) return false;
    const patterns = m.matchPattern.split('|');
    return patterns.some(p => model.toLowerCase().includes(p.toLowerCase()));
  });
  if (candidates.length === 0) return null;
  return candidates.sort((a, b) => (b.matchPattern?.length || 0) - (a.matchPattern?.length || 0))[0];
}

function checkSpeed(profile: Profile, record: Partial<DriveRecord>): { metric: string; expected: number; measured: number; verdict: string }[] {
  const tol = 1 - (profile.tolerancePct / 100);
  const checks = [
    { metric: 'SEQ Read', expected: profile.minSeqR, measured: record.seqRead || 0 },
    { metric: 'SEQ Write', expected: profile.minSeqW, measured: record.seqWrite || 0 },
    { metric: '4K Read', expected: profile.min4kR, measured: record.rndRead || 0 },
    { metric: '4K Write', expected: profile.min4kW, measured: record.rndWrite || 0 },
  ];
  return checks.map(c => ({
    ...c,
    verdict: c.measured >= c.expected ? 'OK' : c.measured >= c.expected * tol ? 'LOW' : 'FAIL'
  }));
}

function computeVerdict(record: Partial<DriveRecord>): string {
  if (record.healthStatus === 'Unhealthy' || (record.wear || 0) >= 90) return 'FAIL';
  if (record.healthStatus === 'Warning' || (record.wear || 0) >= 70) return 'WATCH';
  if (record.extended?.integrity && record.extended.integrity.badBlocks > 0) return 'FAIL';
  return record.speedVerdict === 'FAIL' ? 'FAIL' : record.speedVerdict === 'LOW' ? 'WATCH' : 'PASS';
}

function formatDate(iso: string): string {
  if (!iso) return '-';
  const d = new Date(iso);
  return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

// ==================== CODE39 BARCODE ====================
function code39Svg(text: string, width: number, height: number): string {
  const chars: Record<string, string> = {
    '0':'101001101101','1':'110100101011','2':'101100101011','3':'110110010101',
    '4':'101001101011','5':'110100110101','6':'101100110101','7':'101001011011',
    '8':'110100101101','9':'101100101101','A':'110101001011','B':'101101001011',
    'C':'110110100101','D':'101011001011','E':'110101100101','F':'101101100101',
    'G':'101010011011','H':'110101001101','I':'101101001101','J':'101011001101',
    'K':'110101010011','L':'101101010011','M':'110110101001','N':'101011010011',
    'O':'110101101001','P':'101101101001','Q':'101010110011','R':'110101011001',
    'S':'101101011001','T':'101011011001','U':'110010101011','V':'100110101011',
    'W':'110011010101','X':'100101101011','Y':'110010110101','Z':'100110110101',
    '-':'100101011011','.':'110010101101',' ':'100110101101','*':'100101101101',
  };
  const encoded = '*' + text.toUpperCase() + '*';
  let bars = '';
  let x = 0;
  const barW = Math.max(1, Math.floor(width / (encoded.length * 12)));
  for (const ch of encoded) {
    const pattern = chars[ch] || chars['0'];
    for (let i = 0; i < pattern.length; i++) {
      if (pattern[i] === '1') {
        bars += `<rect x="${x}" y="0" width="${barW}" height="${height - 14}" fill="black"/>`;
      }
      x += barW;
    }
    x += barW;
  }
  return `<svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">
    <rect width="100%" height="100%" fill="white"/>
    ${bars}
    <text x="${width/2}" y="${height - 2}" text-anchor="middle" font-size="10" font-family="monospace">${text}</text>
  </svg>`;
}

// ==================== MAIN APP ====================
export default function App() {
  const [token, setToken] = useState<string>(() => localStorage.getItem('td_token') || '');
  const [user, setUser] = useState<User | null>(null);
  const [view, setView] = useState('login');
  const [serverOnline, setServerOnline] = useState(false);
  const [probeOnline, setProbeOnline] = useState(false);
  const [toast, setToast] = useState('');
  const [drives, setDrives] = useState<DriveRecord[]>([]);
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [labels, setLabels] = useState<Label[]>([]);
  const [models, setModels] = useState<ModelFamily[]>([]);
  const [lifecycle, setLifecycle] = useState<LifecycleEntry[]>([]);
  const [users, setUsers] = useState<User[]>([]);
  const [selectedDrive, setSelectedDrive] = useState<DriveRecord | null>(null);
  const [showUserMenu, setShowUserMenu] = useState(false);

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(''), 3000);
  }, []);

  // Check connectivity
  useEffect(() => {
    console.log('[HEALTH CHECK] API_BASE:', API_BASE);
    console.log('[HEALTH CHECK] PROBE_BASE:', PROBE_BASE);
    
    fetch(`${API_BASE}/api/health`)
      .then(r => {
        console.log('[HEALTH CHECK] Server response status:', r.status);
        return r.json();
      })
      .then(data => {
        console.log('[HEALTH CHECK] Server health data:', data);
        setServerOnline(true);
      })
      .catch(err => {
        console.error('[HEALTH CHECK] Server error:', err);
        setServerOnline(false);
      });
    
    fetch(`${PROBE_BASE}/ping`)
      .then(r => {
        console.log('[HEALTH CHECK] Probe response status:', r.status);
        return r.json();
      })
      .then(data => {
        console.log('[HEALTH CHECK] Probe health data:', data);
        setProbeOnline(true);
      })
      .catch(err => {
        console.error('[HEALTH CHECK] Probe error:', err);
        setProbeOnline(false);
      });
  }, []);

  // Load data when authenticated
  const loadData = useCallback(async () => {
    if (!token) return;
    try {
      const [d, p, l, m, lc] = await Promise.all([
        api('/api/drives', 'GET', null, token),
        api('/api/profiles', 'GET', null, token),
        api('/api/labels', 'GET', null, token),
        api('/api/models', 'GET', null, token),
        api('/api/lifecycle', 'GET', null, token),
      ]);
      setDrives(Array.isArray(d) ? d : []);
      setProfiles(Array.isArray(p) ? p : []);
      setLabels(Array.isArray(l) ? l : []);
      setModels(Array.isArray(m) ? m : []);
      setLifecycle(Array.isArray(lc) ? lc : []);
    } catch (e) { 
      console.error('[LOAD DATA] Error:', e);
      setDrives([]);
      setProfiles([]);
      setLabels([]);
      setModels([]);
      setLifecycle([]);
    }
  }, [token]);

  useEffect(() => {
    if (token) {
      api('/api/me', 'GET', null, token).then(u => {
        setUser(u);
        setView('dashboard');
        loadData();
      }).catch(() => {
        setToken('');
        localStorage.removeItem('td_token');
      });
    }
  }, [token, loadData]);

  const handleLogin = async (username: string, password: string) => {
    try {
      const res = await api('/api/login', 'POST', { username, password });
      setToken(res.token);
      localStorage.setItem('td_token', res.token);
      showToast('Logged in');
    } catch (e: any) { showToast(e.message); }
  };

  const handleRegister = async (username: string, password: string) => {
    try {
      const res = await api('/api/register', 'POST', { username, password });
      setToken(res.token);
      localStorage.setItem('td_token', res.token);
      showToast('Account created');
    } catch (e: any) { showToast(e.message); }
  };

  const handleLogout = async () => {
    try { await api('/api/logout', 'POST', null, token); } catch {}
    setToken('');
    setUser(null);
    localStorage.removeItem('td_token');
    setView('login');
    setShowUserMenu(false);
  };

  const loadUsers = async () => {
    if (user?.role !== 'admin') return;
    try {
      const u = await api('/api/users', 'GET', null, token);
      setUsers(Array.isArray(u) ? u : []);
    } catch (e) {
      console.error('[LOAD USERS] Error:', e);
      setUsers([]);
    }
  };

  // ==================== RENDER ====================
  if (view === 'login' || !user) {
    return <LoginView onLogin={handleLogin} onRegister={handleRegister} serverOnline={serverOnline} />;
  }

  return (
    <div className="min-h-screen flex flex-col">
      {/* Top Bar */}
      <header className="flex items-center justify-between px-4 py-2 border-b border-[var(--border)]" style={{background:'var(--bg-panel)'}}>
        <div className="flex items-center gap-4">
          <h1 className="font-display text-xl font-bold" style={{color:'var(--amber)'}}>⬡ TESTDECK</h1>
          <nav className="flex gap-1">
            {[
              ['dashboard','Dashboard'],['newtest','New Test'],['drives','My Drives'],
              ...(user.role === 'admin' ? [['admin','Admin']] : []),
              ['help','Help']
            ].map(([k,l]) => (
              <button key={k} onClick={() => { setView(k as string); if (k === 'admin') loadUsers(); }}
                className={`px-3 py-1 text-sm rounded transition ${view === k ? 'bg-[var(--amber)] text-black font-semibold' : 'text-[var(--text-secondary)] hover:text-[var(--amber)]'}`}>
                {l}
              </button>
            ))}
          </nav>
        </div>
        <div className="flex items-center gap-4">
          <div className="flex items-center gap-3 text-xs font-mono">
            <span><span className={`led ${serverOnline ? 'led-green' : 'led-red'}`}></span>SERVER</span>
            <span><span className={`led ${probeOnline ? 'led-green' : 'led-off'}`}></span>PROBE</span>
          </div>
          <div className="relative">
            <button 
              onClick={() => setShowUserMenu(!showUserMenu)}
              className="flex items-center gap-2 px-3 py-1 rounded text-sm" 
              style={{background:'var(--bg-card)'}}
            >
              <span className="font-mono">{user.name}</span>
              <span className="badge badge-pass">{user.role}</span>
            </button>
            {showUserMenu && (
              <div className="absolute right-0 top-full mt-1 z-50" style={{background:'var(--bg-card)',border:'1px solid var(--border)',borderRadius:'4px',minWidth:'160px'}}>
                <button onClick={handleLogout} className="block w-full text-left px-4 py-2 text-sm hover:bg-[var(--bg-panel)]">Logout</button>
              </div>
            )}
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="flex-1 p-4 overflow-auto">
        {view === 'dashboard' && <DashboardView drives={drives} models={models} lifecycle={lifecycle} onOpenDrive={setSelectedDrive} />}
        {view === 'newtest' && <NewTestView profiles={profiles} models={models} token={token} probeOnline={probeOnline} onSaved={() => { loadData(); showToast('Record saved'); }} />}
        {view === 'drives' && <DrivesView drives={drives} lifecycle={lifecycle} user={user} token={token} onOpenDrive={setSelectedDrive} onRefresh={loadData} />}
        {view === 'admin' && user.role === 'admin' && <AdminView profiles={profiles} labels={labels} models={models} users={users} token={token} onRefresh={() => { loadData(); loadUsers(); }} showToast={showToast} />}
        {view === 'help' && <HelpView />}
      </main>

      {/* Drawer */}
      {selectedDrive && (
        <DriveDrawer drive={selectedDrive} drives={drives} lifecycle={lifecycle} models={models} labels={labels}
          token={token} onClose={() => setSelectedDrive(null)} onRefresh={loadData} showToast={showToast} />
      )}

      {/* Toast */}
      {toast && <div className="toast font-mono text-sm">{toast}</div>}
    </div>
  );
}

// ==================== LOGIN VIEW ====================
function LoginView({ onLogin, onRegister, serverOnline }: { onLogin: (u: string, p: string) => void; onRegister: (u: string, p: string) => void; serverOnline: boolean }) {
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [bootLog] = useState<string[]>([
    '[BOOT] TestDeck Console v1.0 initializing...',
    '[BOOT] Checking server connectivity...',
    `[BOOT] Server: ${serverOnline ? 'ONLINE' : 'OFFLINE'}`,
    '[BOOT] Loading UI components...',
    '[BOOT] Ready. Awaiting authentication.',
  ]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (mode === 'login') onLogin(username, password);
    else onRegister(username, password);
  };

  return (
    <div className="min-h-screen flex items-center justify-center p-4">
      <div className="flex flex-col md:flex-row gap-8 max-w-4xl w-full">
        <div className="flex-1 panel">
          <h2 className="font-display text-sm mb-3" style={{color:'var(--amber)'}}>SYSTEM LOG</h2>
          <div className="font-mono text-xs space-y-1" style={{color:'var(--text-dim)'}}>
            {bootLog.map((line, i) => (
              <div key={i} className={line.includes('ONLINE') ? 'text-green-400' : line.includes('OFFLINE') ? 'text-red-400' : ''}>{line}</div>
            ))}
            <div className="animate-pulse">█</div>
          </div>
        </div>

        <div className="flex-1 panel">
          <h2 className="font-display text-2xl font-bold mb-6" style={{color:'var(--amber)'}}>
            {mode === 'login' ? '▸ SIGN IN' : '▸ REGISTER'}
          </h2>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label className="block text-xs text-[var(--text-secondary)] mb-1">USERNAME</label>
              <input className="input font-mono" value={username} onChange={e => setUsername(e.target.value)} required />
            </div>
            <div>
              <label className="block text-xs text-[var(--text-secondary)] mb-1">PASSWORD</label>
              <input className="input font-mono" type="password" value={password} onChange={e => setPassword(e.target.value)} required />
            </div>
            <button type="submit" className="btn-primary w-full">{mode === 'login' ? 'AUTHENTICATE' : 'CREATE ACCOUNT'}</button>
          </form>
          <button onClick={() => setMode(mode === 'login' ? 'register' : 'login')}
            className="mt-4 text-sm text-[var(--cyan)] hover:underline">
            {mode === 'login' ? 'Need an account? Register →' : 'Have an account? Sign in →'}
          </button>
        </div>
      </div>
    </div>
  );
}

// ==================== DASHBOARD VIEW ====================
function DashboardView({ drives, models, lifecycle, onOpenDrive }: { drives: DriveRecord[]; models: ModelFamily[]; lifecycle: LifecycleEntry[]; onOpenDrive: (d: DriveRecord) => void }) {
  const totalDrives = drives.length;
  const uniqueSerials = new Set(drives.map(d => d.serial)).size;
  const passCount = drives.filter(d => d.verdict === 'PASS').length;
  const failCount = drives.filter(d => d.verdict === 'FAIL').length;
  const watchCount = drives.filter(d => d.verdict === 'WATCH').length;

  const condData = [
    { name: 'PASS', value: passCount, color: '#10b981' },
    { name: 'WATCH', value: watchCount, color: '#f59e0b' },
    { name: 'FAIL', value: failCount, color: '#ef4444' },
  ];

  const mfrMap: Record<string, { total: number; fails: number; avgSeqW: number; avgWear: number }> = {};
  drives.forEach(d => {
    const mf = matchModelFamily(d.model, models);
    const mfr = mf?.manufacturer || 'Other';
    if (!mfrMap[mfr]) mfrMap[mfr] = { total: 0, fails: 0, avgSeqW: 0, avgWear: 0 };
    mfrMap[mfr].total++;
    if (d.verdict === 'FAIL') mfrMap[mfr].fails++;
    mfrMap[mfr].avgSeqW += d.seqWrite || 0;
    mfrMap[mfr].avgWear += d.wear || 0;
  });
  const mfrSummary = Object.entries(mfrMap).map(([mfr, data]) => ({
    manufacturer: mfr,
    tests: data.total,
    failPct: data.total > 0 ? Math.round(data.fails / data.total * 100) : 0,
    avgSeqW: Math.round(data.avgSeqW / data.total),
    avgWear: Math.round(data.avgWear / data.total * 10) / 10,
  })).sort((a, b) => b.failPct - a.failPct);

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
        <StatTile label="Total Records" value={totalDrives} color="var(--cyan)" />
        <StatTile label="Unique Drives" value={uniqueSerials} color="var(--amber)" />
        <StatTile label="PASS" value={passCount} color="var(--green)" />
        <StatTile label="WATCH" value={watchCount} color="var(--amber)" />
        <StatTile label="FAIL" value={failCount} color="var(--red)" />
      </div>

      <div className="panel">
        <h3 className="font-display text-sm mb-2" style={{color:'var(--amber)'}}>CONDITION DISTRIBUTION</h3>
        <div className="condition-bar">
          {condData.map(c => (
            <div key={c.name} style={{ width: `${totalDrives > 0 ? (c.value / totalDrives * 100) : 0}%`, background: c.color }} />
          ))}
        </div>
      </div>

      <div className="panel">
        <h3 className="font-display text-sm mb-3" style={{color:'var(--amber)'}}>MANUFACTURER SUMMARY</h3>
        <table className="data-table">
          <thead><tr><th>Manufacturer</th><th>Tests</th><th>Fail%</th><th>Avg SEQ W</th><th>Avg Wear</th></tr></thead>
          <tbody>
            {mfrSummary.map(m => (
              <tr key={m.manufacturer}>
                <td>{String(m.manufacturer || '')}</td>
                <td>{m.tests}</td>
                <td>{m.failPct}%</td>
                <td>{m.avgSeqW} MB/s</td>
                <td>{m.avgWear}%</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="panel">
        <h3 className="font-display text-sm mb-3" style={{color:'var(--amber)'}}>RECENT TESTS</h3>
        <table className="data-table">
          <thead><tr><th>Date</th><th>Model</th><th>Serial</th><th>SEQ R/W</th><th>Wear</th><th>Verdict</th></tr></thead>
          <tbody>
            {drives.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()).slice(0, 10).map(d => (
              <tr key={d.id} className="cursor-pointer" onClick={() => onOpenDrive(d)}>
                <td>{formatDate(d.createdAt)}</td>
                <td>{String(d.model || '').substring(0, 25)}</td>
                <td>{String(d.serial || '').substring(0, 12)}</td>
                <td>{d.seqRead}/{d.seqWrite} MB/s</td>
                <td>{d.wear}%</td>
                <td><span className={`badge ${d.verdict === 'PASS' ? 'badge-pass' : d.verdict === 'FAIL' ? 'badge-fail' : 'badge-watch'}`}>{d.verdict}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function StatTile({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <div className="panel text-center">
      <div className="font-mono text-3xl font-bold" style={{color}}>{value}</div>
      <div className="text-xs text-[var(--text-secondary)] mt-1">{label}</div>
    </div>
  );
}

// ==================== NEW TEST VIEW ====================
function NewTestView({ profiles, models, token, probeOnline, onSaved }: { profiles: Profile[]; models: ModelFamily[]; token: string; probeOnline: boolean; onSaved: () => void }) {
  const [step, setStep] = useState(1);
  const [probeDrives, setProbeDrives] = useState<ProbeDrive[]>([]);
  const [selectedDrive, setSelectedDrive] = useState<ProbeDrive | null>(null);
  const [modules, setModules] = useState({ seq: true, rnd: false, qd: false, mix: false, sustained: false, verify: false });
  const [running, setRunning] = useState<string | null>(null);
  const [results, setResults] = useState<any>({});
  const [selectedProfile, setSelectedProfile] = useState<Profile | null>(null);
  const [batch, setBatch] = useState('');
  const [notes, setNotes] = useState('');
  const [verdict, setVerdict] = useState('PASS');

  useEffect(() => {
    if (probeOnline) {
      probe('/drives')
        .then(d => {
          console.log('[PROBE DRIVES] Response:', d);
          const drives = Array.isArray(d) ? d : [];
          setProbeDrives(drives);
        })
        .catch((e) => {
          console.error('[PROBE DRIVES] Error:', e);
          setProbeDrives([]);
        });
    } else {
      setProbeDrives([]);
    }
  }, [probeOnline]);

  useEffect(() => {
    if (selectedDrive && profiles.length > 0) {
      const p = matchProfile(selectedDrive.model, selectedDrive.bus, selectedDrive.media, profiles);
      if (p) setSelectedProfile(p);
    }
  }, [selectedDrive, profiles]);

  const runModule = async (mod: string) => {
    if (!selectedDrive || !selectedDrive.letters || selectedDrive.letters.length === 0) return;
    const validLetters = selectedDrive.letters.filter((l: any) => l && typeof l === 'string' && l.trim() !== '');
    if (validLetters.length === 0) {
      console.error('[BENCHMARK] No valid drive letters found');
      return;
    }
    const letter = validLetters[0];
    console.log('[BENCHMARK] Using drive letter:', letter);
    setRunning(mod);
    try {
      let result: any;
      switch (mod) {
        case 'seq':
          result = await probe('/bench/seq', { drive: letter, op: 'both', sizeMB: 64 });
          break;
        case 'rnd':
          result = await probe('/bench/rnd', { drive: letter, op: 'both', seconds: 3, sizeMB: 64 });
          break;
        case 'qd':
          const [seqQ8R, seqQ8W, rndQ32R, rndQ32W] = await Promise.all([
            probe('/bench/qd', { drive: letter, kind: 'seq', q: 8, seconds: 3, op: 'read' }),
            probe('/bench/qd', { drive: letter, kind: 'seq', q: 8, seconds: 3, op: 'write' }),
            probe('/bench/qd', { drive: letter, kind: 'rnd', q: 32, seconds: 3, op: 'read' }),
            probe('/bench/qd', { drive: letter, kind: 'rnd', q: 32, seconds: 3, op: 'write' }),
          ]);
          result = { seqQ8R: seqQ8R.mbps, seqQ8W: seqQ8W.mbps, rndQ32R: rndQ32R.mbps, rndQ32W: rndQ32W.mbps };
          break;
        case 'mix':
          result = await probe('/bench/mix', { drive: letter, seconds: 5, sizeMB: 64 });
          break;
        case 'sustained':
          result = await probe('/bench/sustained', { drive: letter, sizeMB: 256, percent: 0 });
          break;
        case 'verify':
          result = await probe('/bench/verify', { drive: letter, sizeMB: 16 });
          break;
      }
      console.log(`[BENCHMARK] ${mod} result:`, result);
      setResults((prev: any) => ({ ...prev, [mod]: result }));
    } catch (e: any) {
      console.error(`[BENCHMARK] ${mod} error:`, e);
      setResults((prev: any) => ({ ...prev, [mod]: { error: e.message } }));
    }
    setRunning(null);
  };

  const runChecked = async () => {
    const checked = Object.entries(modules).filter(([, v]) => v).map(([k]) => k);
    for (const mod of checked) {
      await runModule(mod);
    }
    setStep(3);
  };

  const saveRecord = async () => {
    console.log('[SAVE RECORD] Starting save...');
    if (!selectedDrive) return;
    const speedChecks = selectedProfile ? checkSpeed(selectedProfile, {
      seqRead: results.seq?.readMbps || 0,
      seqWrite: results.seq?.writeMbps || 0,
      rndRead: results.rnd?.readMbps || 0,
      rndWrite: results.rnd?.writeMbps || 0,
    }) : [];
    const speedVerdict = speedChecks.some(c => c.verdict === 'FAIL') ? 'FAIL' : speedChecks.some(c => c.verdict === 'LOW') ? 'LOW' : 'OK';

    const record: any = {
      serial: selectedDrive.serial || 'UNKNOWN',
      model: selectedDrive.model,
      firmware: selectedDrive.firmware,
      capacityGB: selectedDrive.capacityGB,
      bus: selectedDrive.bus,
      media: selectedDrive.media,
      healthStatus: selectedDrive.healthStatus || 'Unknown',
      wear: selectedDrive.wear || 0,
      tempC: selectedDrive.tempC || 0,
      readErrors: selectedDrive.readErrors || 0,
      writeErrors: selectedDrive.writeErrors || 0,
      seqRead: results.seq?.readMbps || 0,
      seqWrite: results.seq?.writeMbps || 0,
      rndRead: results.rnd?.readMbps || 0,
      rndWrite: results.rnd?.writeMbps || 0,
      rndReadIops: results.rnd?.readIops || 0,
      rndWriteIops: results.rnd?.writeIops || 0,
      batch,
      method: 'probe',
      healthScore: selectedDrive.wear ? 100 - selectedDrive.wear : 50,
      lifePct: selectedDrive.wear ? 100 - selectedDrive.wear : 50,
      profileId: selectedProfile?.id || '',
      profileName: selectedProfile?.name || '',
      speedVerdict,
      verdict,
      notes,
      extended: {
        mix: results.mix ? { readMbps: results.mix.readMbps, writeMbps: results.mix.writeMbps, iops: (results.mix.readIops || 0) + (results.mix.writeIops || 0) } : undefined,
        qd: results.qd ? { seqQ8R: results.qd.seqQ8R, seqQ8W: results.qd.seqQ8W, rndQ32R: results.qd.rndQ32R, rndQ32W: results.qd.rndQ32W } : undefined,
        sustained: results.sustained ? { cacheMB: results.sustained.cacheMB, sustainedMbps: results.sustained.sustainedMbps, maxTemp: results.sustained.maxTemp, sizeMB: results.sustained.sizeMB, series: results.sustained.series } : undefined,
        integrity: results.verify ? { testedMB: results.verify.testedMB, badBlocks: results.verify.badBlocks, firstBadMB: results.verify.firstBadMB } : undefined,
      },
    };

    try {
      console.log('[SAVE RECORD] Calling API to save record...');
      await api('/api/drives', 'POST', record, token);
      console.log('[SAVE RECORD] API call successful, calling onSaved...');
      onSaved();
      console.log('[SAVE RECORD] onSaved called, resetting state...');
      setStep(1);
      setSelectedDrive(null);
      setResults({});
      setBatch('');
      setNotes('');
    } catch (e: any) { alert(e.message); }
  };

  return (
    <div className="max-w-5xl mx-auto space-y-6">
      <div className="flex items-center gap-2 font-mono text-sm">
        {[1,2,3,4].map(s => (
          <React.Fragment key={s}>
            <div className={`w-8 h-8 rounded-full flex items-center justify-center font-bold ${step >= s ? 'bg-[var(--amber)] text-black' : 'bg-[var(--bg-card)] text-[var(--text-dim)]'}`}>{s}</div>
            {s < 4 && <div className={`flex-1 h-0.5 ${step > s ? 'bg-[var(--amber)]' : 'bg-[var(--border)]'}`}></div>}
          </React.Fragment>
        ))}
      </div>

      {step === 1 && (
        <div className="panel">
          <h3 className="font-display text-lg mb-4" style={{color:'var(--amber)'}}>SELECT DRIVE</h3>
          {!probeOnline && <p className="text-[var(--red)] mb-4">Probe not connected. Start probe.ps1 on this machine.</p>}
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
            {probeDrives.map((d, i) => {
              const letters = Array.isArray(d.letters) ? d.letters : [];
              const validLetters = letters.filter((l: any) => l && typeof l === 'string' && l.trim() !== '');
              return (
                <div key={i} onClick={() => { setSelectedDrive(d); setStep(2); }}
                  className={`p-3 rounded cursor-pointer border transition ${selectedDrive === d ? 'border-[var(--amber)] bg-[var(--bg-card)]' : 'border-[var(--border)] hover:border-[var(--cyan)]'}`}>
                  <div className="font-mono text-sm font-bold" style={{color:'var(--cyan)'}}>{d.model?.substring(0, 30) || 'Unknown'}</div>
                  <div className="text-xs text-[var(--text-secondary)] mt-1">
                    {d.capacityGB || 0} GB | {d.bus || 'Unknown'} | {d.media || 'Unknown'}
                  </div>
                  <div className="text-xs text-[var(--text-dim)] mt-1">
                    SN: {d.serial?.substring(0, 16) || 'N/A'} | FW: {d.firmware || 'N/A'}
                  </div>
                  <div className="flex gap-2 mt-2">
                    {validLetters.map((l, idx) => <span key={idx} className="badge badge-pass">{l}:</span>)}
                    {d.wear != null && <span className="text-xs" style={{color: d.wear > 70 ? 'var(--red)' : 'var(--amber)'}}>Wear: {d.wear}%</span>}
                  </div>
                  {!d.relOk && d.relErr && <div className="text-xs text-[var(--text-dim)] mt-1 italic">⚠ {d.relErr?.substring(0, 40)}</div>}
                </div>
              );
            })}
          </div>
          {probeDrives.length === 0 && probeOnline && <p className="text-[var(--text-dim)]">No drives detected.</p>}
        </div>
      )}

      {step === 2 && selectedDrive && (() => {
        const letters = Array.isArray(selectedDrive.letters) ? selectedDrive.letters : [];
        const validLetters = letters.filter((l: any) => l && typeof l === 'string' && l.trim() !== '');
        if (validLetters.length === 0) {
          return (
            <div className="panel space-y-4">
              <h3 className="font-display text-lg" style={{color:'var(--amber)'}}>BENCHMARK MODULES</h3>
              <p className="text-[var(--red)]">This drive has no assigned letter.</p>
              <button onClick={() => setStep(1)} className="btn-secondary">← Back</button>
            </div>
          );
        }
        return (
        <div className="panel space-y-4">
          <h3 className="font-display text-lg" style={{color:'var(--amber)'}}>BENCHMARK MODULES</h3>
          <div className="grid grid-cols-2 md:grid-cols-3 gap-2 text-sm">
            <div className="p-2 rounded" style={{background:'var(--bg-card)'}}>
              <span style={{color:'#94a3b8'}}>Drive:</span> <span className="font-mono">{selectedDrive.model?.substring(0, 20) || 'Unknown'}</span>
            </div>
            <div className="p-2 rounded" style={{background:'var(--bg-card)'}}>
              <span style={{color:'#94a3b8'}}>Volume:</span> <span className="font-mono">{validLetters[0]}:</span>
            </div>
            <div className="p-2 rounded" style={{background:'var(--bg-card)'}}>
              <span style={{color:'#94a3b8'}}>Profile:</span> <span className="font-mono">{selectedProfile?.name || 'None'}</span>
            </div>
          </div>

          <div className="space-y-2">
            {Object.entries(modules).map(([mod, checked]) => (
              <div key={mod} className="flex items-center gap-3 p-2 rounded" style={{background:'var(--bg-card)'}}>
                <input type="checkbox" checked={checked} onChange={e => setModules(prev => ({...prev, [mod]: e.target.checked}))} />
                <span className="font-mono text-sm flex-1">{mod.toUpperCase()}</span>
                <button onClick={() => runModule(mod)} disabled={running !== null}
                  className="px-3 py-1 text-xs rounded bg-[var(--cyan)] text-black font-bold disabled:opacity-50">
                  {running === mod ? '⏳ Running...' : '▶ Run'}
                </button>
                {results[mod] && !results[mod].error && <span className="text-xs text-[var(--green)]">✓ Done</span>}
                {results[mod]?.error && <span className="text-xs text-[var(--red)]">✗ Error</span>}
              </div>
            ))}
          </div>

          {running && (
            <div className="w-full h-3 rounded overflow-hidden" style={{background:'var(--bg-card)'}}>
              <div className="h-full progress-striped" style={{width:'100%'}}></div>
            </div>
          )}

          <div className="flex gap-3">
            <button onClick={() => setStep(1)} className="btn-secondary">← Back</button>
            <button onClick={runChecked} disabled={running !== null} className="btn-primary">▶ Run Checked</button>
            <button onClick={() => setStep(3)} className="btn-secondary">Review →</button>
          </div>
        </div>
        );
      })()}

      {step === 3 && selectedDrive && (
        <div className="panel space-y-4">
          <h3 className="font-display text-lg" style={{color:'var(--amber)'}}>REVIEW RESULTS</h3>

          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            {results.seq && <ResultTile label="SEQ Read" value={`${results.seq.readMbps || 0} MB/s`} />}
            {results.seq && <ResultTile label="SEQ Write" value={`${results.seq.writeMbps || 0} MB/s`} />}
            {results.rnd && <ResultTile label="4K Read" value={`${results.rnd.readMbps || 0} MB/s`} />}
            {results.rnd && <ResultTile label="4K Write" value={`${results.rnd.writeMbps || 0} MB/s`} />}
          </div>

          {selectedProfile && results.seq && (
            <div>
              <h4 className="text-sm font-bold mb-2" style={{color:'var(--cyan)'}}>SPEED PROFILE: {selectedProfile.name}</h4>
              <table className="data-table">
                <thead><tr><th>Metric</th><th>Expected</th><th>Measured</th><th>Verdict</th></tr></thead>
                <tbody>
                  {checkSpeed(selectedProfile, { seqRead: results.seq?.readMbps, seqWrite: results.seq?.writeMbps, rndRead: results.rnd?.readMbps, rndWrite: results.rnd?.writeMbps }).map(c => (
                    <tr key={c.metric}>
                      <td>{c.metric}</td><td>{c.expected} MB/s</td><td>{c.measured} MB/s</td>
                      <td><span className={`badge ${c.verdict === 'OK' ? 'badge-pass' : c.verdict === 'LOW' ? 'badge-watch' : 'badge-fail'}`}>{c.verdict}</span></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          <div>
            <label className="block text-xs text-[var(--text-secondary)] mb-1">SPEED PROFILE</label>
            <select className="input" value={selectedProfile?.id || ''} onChange={e => setSelectedProfile(profiles.find(p => p.id === e.target.value) || null)}>
              <option value="">-- Select Profile --</option>
              {profiles.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </div>

          <div>
            <label className="block text-xs text-[var(--text-secondary)] mb-1">FINAL VERDICT</label>
            <div className="flex gap-2">
              {['PASS','WATCH','FAIL'].map(v => (
                <button key={v} onClick={() => setVerdict(v)}
                  className={`px-4 py-2 rounded font-bold text-sm ${verdict === v ? (v === 'PASS' ? 'bg-[var(--green)] text-black' : v === 'FAIL' ? 'bg-[var(--red)] text-white' : 'bg-[var(--amber)] text-black') : 'border border-[var(--border)] text-[var(--text-secondary)]'}`}>
                  {v}
                </button>
              ))}
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-xs text-[var(--text-secondary)] mb-1">BATCH / PO</label>
              <input className="input font-mono" value={batch} onChange={e => setBatch(e.target.value)} placeholder="e.g., LOT-2024-001" />
            </div>
            <div>
              <label className="block text-xs text-[var(--text-secondary)] mb-1">NOTES</label>
              <input className="input" value={notes} onChange={e => setNotes(e.target.value)} placeholder="Optional notes..." />
            </div>
          </div>

          <div className="flex gap-3">
            <button onClick={() => setStep(2)} className="btn-secondary">← Back</button>
            <button onClick={saveRecord} className="btn-primary">💾 SAVE RECORD</button>
          </div>
        </div>
      )}

      {step === 4 && (
        <div className="panel text-center py-12">
          <div className="text-4xl mb-4">✓</div>
          <h3 className="font-display text-xl" style={{color:'var(--green)'}}>RECORD SAVED</h3>
          <button onClick={() => setStep(1)} className="btn-primary mt-4">New Test</button>
        </div>
      )}
    </div>
  );
}

function ResultTile({ label, value }: { label: string; value: string }) {
  return (
    <div className="p-3 rounded text-center" style={{background:'var(--bg-card)'}}>
      <div className="font-mono text-lg font-bold" style={{color:'var(--cyan)'}}>{value}</div>
      <div className="text-xs text-[var(--text-secondary)]">{label}</div>
    </div>
  );
}

// ==================== DRIVES VIEW ====================
function DrivesView({ drives, lifecycle, user, token, onOpenDrive, onRefresh }: { drives: DriveRecord[]; lifecycle: LifecycleEntry[]; user: User; token: string; onOpenDrive: (d: DriveRecord) => void; onRefresh: () => void }) {
  const [filter, setFilter] = useState<'my' | 'all'>(user.role === 'admin' ? 'all' : 'my');
  const [search, setSearch] = useState('');
  const [verdictFilter, setVerdictFilter] = useState('');
  const [sortKey, setSortKey] = useState('createdAt');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');

  const filtered = drives
    .filter(d => filter === 'my' ? d.owner === user.name : true)
    .filter(d => !search || d.model?.toLowerCase().includes(search.toLowerCase()) || d.serial?.toLowerCase().includes(search.toLowerCase()))
    .filter(d => !verdictFilter || d.verdict === verdictFilter)
    .sort((a, b) => {
      const aVal = (a as any)[sortKey];
      const bVal = (b as any)[sortKey];
      const cmp = typeof aVal === 'number' ? aVal - bVal : String(aVal).localeCompare(String(bVal));
      return sortDir === 'asc' ? cmp : -cmp;
    });

  const handleSort = (key: string) => {
    if (sortKey === key) setSortDir(sortDir === 'asc' ? 'desc' : 'asc');
    else { setSortKey(key); setSortDir('desc'); }
  };

  const exportCSV = () => {
    const headers = ['Date','Model','Serial','Capacity','Bus','Media','Health','Wear','SeqR','SeqW','RndR','RndW','Verdict','Batch','Owner'];
    const rows = filtered.map(d => [formatDate(d.createdAt), String(d.model || ''), String(d.serial || ''), d.capacityGB, String(d.bus || ''), String(d.media || ''), String(d.healthStatus || ''), d.wear, d.seqRead, d.seqWrite, d.rndRead, d.rndWrite, d.verdict, String(d.batch || ''), d.owner]);
    const csv = [headers, ...rows].map(r => r.map(c => `"${c}"`).join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = `testdeck-drives-${new Date().toISOString().split('T')[0]}.csv`;
    a.click(); URL.revokeObjectURL(url);
  };

  const getLifecycleStatus = (serial: string) => {
    const lc = lifecycle.find(l => l.serial === serial);
    return lc?.status || '-';
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex gap-1">
          <button onClick={() => setFilter('my')} className={`px-3 py-1 text-sm rounded ${filter === 'my' ? 'bg-[var(--amber)] text-black font-bold' : 'text-[var(--text-secondary)]'}`}>My Drives</button>
          {user.role === 'admin' && <button onClick={() => setFilter('all')} className={`px-3 py-1 text-sm rounded ${filter === 'all' ? 'bg-[var(--amber)] text-black font-bold' : 'text-[var(--text-secondary)]'}`}>All Drives</button>}
        </div>
        <input className="input max-w-xs" placeholder="Search model/serial..." value={search} onChange={e => setSearch(e.target.value)} />
        <select className="input max-w-[120px]" value={verdictFilter} onChange={e => setVerdictFilter(e.target.value)}>
          <option value="">All Verdicts</option>
          <option value="PASS">PASS</option>
          <option value="WATCH">WATCH</option>
          <option value="FAIL">FAIL</option>
        </select>
        <button onClick={exportCSV} className="btn-secondary text-sm">📥 CSV</button>
        <button onClick={onRefresh} className="btn-secondary text-sm">↻ Refresh</button>
      </div>

      <div className="panel overflow-x-auto">
        <table className="data-table">
          <thead>
            <tr>
              <th onClick={() => handleSort('createdAt')}>Date</th>
              <th onClick={() => handleSort('model')}>Model</th>
              <th onClick={() => handleSort('serial')}>Serial</th>
              <th onClick={() => handleSort('capacityGB')}>Cap</th>
              <th>Status</th>
              <th onClick={() => handleSort('seqWrite')}>SEQ W</th>
              <th onClick={() => handleSort('wear')}>Wear</th>
              <th onClick={() => handleSort('verdict')}>Verdict</th>
              <th>Owner</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map(d => (
              <tr key={d.id} className="cursor-pointer" onClick={() => onOpenDrive(d)}>
                <td>{formatDate(d.createdAt)}</td>
                <td>{String(d.model || '').substring(0, 25)}</td>
                <td>{String(d.serial || '').substring(0, 14)}</td>
                <td>{d.capacityGB}G</td>
                <td><span className="text-xs">{getLifecycleStatus(d.serial)}</span></td>
                <td>{d.seqWrite} MB/s</td>
                <td style={{color: (d.wear||0) > 70 ? 'var(--red)' : (d.wear||0) > 40 ? 'var(--amber)' : 'var(--green)'}}>{d.wear}%</td>
                <td><span className={`badge ${d.verdict === 'PASS' ? 'badge-pass' : d.verdict === 'FAIL' ? 'badge-fail' : 'badge-watch'}`}>{d.verdict}</span></td>
                <td className="text-xs">{d.owner}</td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={9} className="text-center text-[var(--text-dim)] py-8">No records found</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ==================== DRIVE DRAWER ====================
function DriveDrawer({ drive, drives, lifecycle, models, labels, token, onClose, onRefresh, showToast }: {
  drive: DriveRecord; drives: DriveRecord[]; lifecycle: LifecycleEntry[]; models: ModelFamily[]; labels: Label[];
  token: string; onClose: () => void; onRefresh: () => void; showToast: (m: string) => void;
}) {
  const [lcStatus, setLcStatus] = useState('');
  const [lcNote, setLcNote] = useState('');
  const [labelSize, setLabelSize] = useState(labels[0] || { widthMm: 100, heightMm: 25, name: '', id: '' });

  useEffect(() => {
    const lc = lifecycle.find(l => l.serial === drive.serial);
    if (lc) setLcStatus(lc.status);
  }, [drive, lifecycle]);

  const history = drives.filter(d => d.serial === drive.serial).sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
  const familyModel = matchModelFamily(drive.model, models);

  const updateLifecycle = async () => {
    try {
      await api('/api/lifecycle', 'POST', { serial: drive.serial, status: lcStatus, note: lcNote }, token);
      onRefresh();
      showToast('Lifecycle updated');
    } catch (e: any) { showToast(e.message); }
  };

  const deleteDrive = async () => {
    if (!confirm('Delete this record?')) return;
    try {
      await api(`/api/drives/${drive.id}`, 'DELETE', null, token);
      onRefresh();
      onClose();
      showToast('Record deleted');
    } catch (e: any) { showToast(e.message); }
  };

  const copySerial = () => {
    navigator.clipboard.writeText(drive.serial || '');
    showToast('Serial copied');
  };

  return (
    <>
      <div className="drawer-overlay" onClick={onClose}></div>
      <div className="drawer p-6">
        <div className="flex items-center justify-between mb-6">
          <h2 className="font-display text-xl font-bold" style={{color:'var(--amber)'}}>DRIVE RECORD</h2>
          <button onClick={onClose} className="text-2xl text-[var(--text-dim)] hover:text-[var(--text-primary)]">×</button>
        </div>

        <div className="grid grid-cols-2 gap-3 mb-4">
          <div className="p-3 rounded" style={{background:'var(--bg-card)'}}>
            <div className="text-xs text-[var(--text-secondary)]">Health</div>
            <div className="font-mono font-bold" style={{color: String(drive.healthStatus) === 'Healthy' ? 'var(--green)' : 'var(--red)'}}>{String(drive.healthStatus || 'Unknown')}</div>
          </div>
          <div className="p-3 rounded" style={{background:'var(--bg-card)'}}>
            <div className="text-xs text-[var(--text-secondary)]">Wear</div>
            <div className="font-mono font-bold" style={{color: (drive.wear||0) > 70 ? 'var(--red)' : 'var(--amber)'}}>{drive.wear || 0}%</div>
          </div>
          <div className="p-3 rounded" style={{background:'var(--bg-card)'}}>
            <div className="text-xs text-[var(--text-secondary)]">Verdict</div>
            <span className={`badge ${drive.verdict === 'PASS' ? 'badge-pass' : drive.verdict === 'FAIL' ? 'badge-fail' : 'badge-watch'}`}>{drive.verdict}</span>
          </div>
          <div className="p-3 rounded" style={{background:'var(--bg-card)'}}>
            <div className="text-xs text-[var(--text-secondary)]">Temperature</div>
            <div className="font-mono font-bold">{drive.tempC || '-'}°C</div>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-2 mb-4 text-sm font-mono">
          <div className="p-2 rounded" style={{background:'var(--bg-card)'}}>SEQ R: {drive.seqRead} MB/s</div>
          <div className="p-2 rounded" style={{background:'var(--bg-card)'}}>SEQ W: {drive.seqWrite} MB/s</div>
          <div className="p-2 rounded" style={{background:'var(--bg-card)'}}>4K R: {drive.rndRead} MB/s</div>
          <div className="p-2 rounded" style={{background:'var(--bg-card)'}}>4K W: {drive.rndWrite} MB/s</div>
        </div>

        <div className="mb-4 text-sm">
          <h4 className="font-bold mb-2" style={{color:'var(--cyan)'}}>IDENTITY</h4>
          <div className="grid grid-cols-2 gap-1 font-mono text-xs">
            <span className="text-[var(--text-secondary)]">Model:</span><span>{String(drive.model || '')}</span>
            <span className="text-[var(--text-secondary)]">Serial:</span><span>{String(drive.serial || '')}</span>
            <span className="text-[var(--text-secondary)]">FW:</span><span>{String(drive.firmware || '')}</span>
            <span className="text-[var(--text-secondary)]">Capacity:</span><span>{drive.capacityGB} GB</span>
            <span className="text-[var(--text-secondary)]">Bus:</span><span>{String(drive.bus || '')}</span>
            <span className="text-[var(--text-secondary)]">Media:</span><span>{String(drive.media || '')}</span>
            <span className="text-[var(--text-secondary)]">Family:</span><span>{familyModel?.family || '-'}</span>
            <span className="text-[var(--text-secondary)]">Batch:</span><span>{String(drive.batch || '-')}</span>
          </div>
        </div>

        <div className="mb-4">
          <h4 className="text-sm font-bold mb-2" style={{color:'var(--cyan)'}}>LIFECYCLE STATUS</h4>
          <div className="flex gap-2 items-center">
            <select className="input max-w-[150px]" value={lcStatus} onChange={e => setLcStatus(e.target.value)}>
              {['INCOMING','TESTED','STOCK','DEPLOYED','RMA','RETIRED'].map(s => <option key={s} value={s}>{s}</option>)}
            </select>
            <input className="input flex-1" placeholder="Note..." value={lcNote} onChange={e => setLcNote(e.target.value)} />
            <button onClick={updateLifecycle} className="btn-secondary text-sm">Update</button>
          </div>
        </div>

        <div className="flex flex-wrap gap-2">
          <button onClick={copySerial} className="btn-secondary text-sm">📋 Copy Serial</button>
          <button onClick={deleteDrive} className="btn-danger text-sm">🗑 Delete</button>
        </div>

        {drive.notes && <div className="mt-4 text-sm text-[var(--text-secondary)] italic">Notes: {drive.notes}</div>}
      </div>
    </>
  );
}

// ==================== ADMIN VIEW ====================
function AdminView({ profiles, labels, models, users, token, onRefresh, showToast }: {
  profiles: Profile[]; labels: Label[]; models: ModelFamily[]; users: User[];
  token: string; onRefresh: () => void; showToast: (m: string) => void;
}) {
  const [tab, setTab] = useState<'profiles' | 'labels' | 'models' | 'users'>('profiles');

  return (
    <div className="space-y-4">
      <div className="flex gap-1">
        {(['profiles','labels','models','users'] as const).map(t => (
          <button key={t} onClick={() => setTab(t)}
            className={`px-4 py-2 text-sm rounded capitalize ${tab === t ? 'bg-[var(--amber)] text-black font-bold' : 'text-[var(--text-secondary)] hover:text-[var(--amber)]'}`}>
            {t}
          </button>
        ))}
      </div>

      {tab === 'profiles' && <AdminProfiles profiles={profiles} token={token} onRefresh={onRefresh} showToast={showToast} />}
      {tab === 'labels' && <AdminLabels labels={labels} token={token} onRefresh={onRefresh} showToast={showToast} />}
      {tab === 'models' && <AdminModels models={models} token={token} onRefresh={onRefresh} showToast={showToast} />}
      {tab === 'users' && <AdminUsers users={users} token={token} onRefresh={onRefresh} showToast={showToast} />}
    </div>
  );
}

function AdminProfiles({ profiles, token, onRefresh, showToast }: { profiles: Profile[]; token: string; onRefresh: () => void; showToast: (m: string) => void }) {
  const [editing, setEditing] = useState<Profile | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState<Partial<Profile>>({ name:'', matchSubstring:'', bus:'ANY', media:'ANY', minSeqR:500, minSeqW:400, min4kR:25, min4kW:50, tolerancePct:15, ratedTBW:0 });

  const startEdit = (p: Profile) => { setEditing(p); setForm(p); setShowForm(true); };
  const startNew = () => { setEditing(null); setForm({ name:'', matchSubstring:'', bus:'ANY', media:'ANY', minSeqR:500, minSeqW:400, min4kR:25, min4kW:50, tolerancePct:15, ratedTBW:0 }); setShowForm(true); };
  const cancelEdit = () => { 
    setEditing(null); 
    setShowForm(false);
    setForm({ name:'', matchSubstring:'', bus:'ANY', media:'ANY', minSeqR:500, minSeqW:400, min4kR:25, min4kW:50, tolerancePct:15, ratedTBW:0 }); 
  };

  const save = async () => {
    try {
      if (editing) await api(`/api/profiles/${editing.id}`, 'PATCH', form, token);
      else await api('/api/profiles', 'POST', form, token);
      onRefresh();
      setEditing(null);
      setShowForm(false);
      setForm({ name:'', matchSubstring:'', bus:'ANY', media:'ANY', minSeqR:500, minSeqW:400, min4kR:25, min4kW:50, tolerancePct:15, ratedTBW:0 });
      showToast('Profile saved');
    } catch (e: any) { 
      console.error('[PROFILE SAVE] Error:', e);
      showToast(e.message || 'Failed to save profile'); 
    }
  };

  const remove = async (id: string) => {
    if (!confirm('Delete profile?')) return;
    try { await api(`/api/profiles/${id}`, 'DELETE', null, token); onRefresh(); showToast('Deleted'); } catch (e: any) { showToast(e.message); }
  };

  return (
    <div className="panel space-y-4">
      <div className="flex justify-between items-center">
        <h3 className="font-display" style={{color:'var(--amber)'}}>SPEED PROFILES</h3>
        <button onClick={startNew} className="btn-primary text-sm">+ New Profile</button>
      </div>
      {showForm ? (
        <div className="p-4 rounded space-y-3" style={{background:'var(--bg-card)'}}>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            <div><label className="text-xs text-[var(--text-secondary)]">Name</label><input className="input" value={form.name||''} onChange={e => setForm({...form, name: e.target.value})} /></div>
            <div><label className="text-xs text-[var(--text-secondary)]">Match</label><input className="input" value={form.matchSubstring||''} onChange={e => setForm({...form, matchSubstring: e.target.value})} /></div>
            <div><label className="text-xs text-[var(--text-secondary)]">Bus</label>
              <select className="input" value={form.bus||'ANY'} onChange={e => setForm({...form, bus: e.target.value})}>
                <option>ANY</option><option>SATA</option><option>NVMe</option><option>USB</option>
              </select></div>
            <div><label className="text-xs text-[var(--text-secondary)]">Media</label>
              <select className="input" value={form.media||'ANY'} onChange={e => setForm({...form, media: e.target.value})}>
                <option>ANY</option><option>SSD</option><option>HDD</option>
              </select></div>
          </div>
          <div className="flex gap-2">
            <button onClick={save} className="btn-primary text-sm">Save</button>
            <button onClick={cancelEdit} className="btn-secondary text-sm">Cancel</button>
          </div>
        </div>
      ) : null}
      <table className="data-table">
        <thead><tr><th>Name</th><th>Match</th><th>Bus</th><th>Media</th><th>Actions</th></tr></thead>
        <tbody>
          {profiles.map(p => (
            <tr key={p.id}>
              <td>{p.name}</td>
              <td>{p.matchSubstring || '-'}</td>
              <td>{p.bus}</td>
              <td>{p.media}</td>
              <td>
                <button onClick={() => startEdit(p)} className="text-[var(--cyan)] mr-2">✎</button>
                <button onClick={() => remove(p.id)} className="text-[var(--red)]">✕</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AdminLabels({ labels, token, onRefresh, showToast }: { labels: Label[]; token: string; onRefresh: () => void; showToast: (m: string) => void }) {
  const [form, setForm] = useState({ name: '', widthMm: 100, heightMm: 25 });
  const [editId, setEditId] = useState<string | null>(null);

  const save = async () => {
    try {
      if (editId) await api(`/api/labels/${editId}`, 'PATCH', form, token);
      else await api('/api/labels', 'POST', form, token);
      onRefresh();
      setForm({ name: '', widthMm: 100, heightMm: 25 });
      setEditId(null);
      showToast('Label saved');
    } catch (e: any) { showToast(e.message); }
  };

  const remove = async (id: string) => {
    if (!confirm('Delete?')) return;
    try { await api(`/api/labels/${id}`, 'DELETE', null, token); onRefresh(); showToast('Deleted'); } catch (e: any) { showToast(e.message); }
  };

  return (
    <div className="panel space-y-4">
      <h3 className="font-display" style={{color:'var(--amber)'}}>LABEL SIZES</h3>
      <div className="flex gap-3 items-end">
        <div><label className="text-xs text-[var(--text-secondary)]">Name</label><input className="input" value={form.name} onChange={e => setForm({...form, name: e.target.value})} /></div>
        <div><label className="text-xs text-[var(--text-secondary)]">Width (mm)</label><input className="input" type="number" value={form.widthMm} onChange={e => setForm({...form, widthMm: +e.target.value})} /></div>
        <div><label className="text-xs text-[var(--text-secondary)]">Height (mm)</label><input className="input" type="number" value={form.heightMm} onChange={e => setForm({...form, heightMm: +e.target.value})} /></div>
        <button onClick={save} className="btn-primary text-sm">{editId ? 'Update' : 'Add'}</button>
      </div>
      <table className="data-table">
        <thead><tr><th>Name</th><th>Width</th><th>Height</th><th>Actions</th></tr></thead>
        <tbody>
          {labels.map(l => (
            <tr key={l.id}>
              <td>{l.name}</td>
              <td>{l.widthMm}mm</td>
              <td>{l.heightMm}mm</td>
              <td>
                <button onClick={() => { setEditId(l.id); setForm({ name: l.name, widthMm: l.widthMm, heightMm: l.heightMm }); }} className="text-[var(--cyan)] mr-2">✎</button>
                <button onClick={() => remove(l.id)} className="text-[var(--red)]">✕</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AdminModels({ models, token, onRefresh, showToast }: { models: ModelFamily[]; token: string; onRefresh: () => void; showToast: (m: string) => void }) {
  const [form, setForm] = useState({ family: '', manufacturer: '', matchPattern: '' });
  const [editId, setEditId] = useState<string | null>(null);

  const save = async () => {
    try {
      if (editId) await api(`/api/models/${editId}`, 'PATCH', form, token);
      else await api('/api/models', 'POST', form, token);
      onRefresh();
      setForm({ family: '', manufacturer: '', matchPattern: '' });
      setEditId(null);
      showToast('Model saved');
    } catch (e: any) { showToast(e.message); }
  };

  const remove = async (id: string) => {
    if (!confirm('Delete?')) return;
    try { await api(`/api/models/${id}`, 'DELETE', null, token); onRefresh(); showToast('Deleted'); } catch (e: any) { showToast(e.message); }
  };

  return (
    <div className="panel space-y-4">
      <h3 className="font-display" style={{color:'var(--amber)'}}>MODEL CATALOG</h3>
      <div className="flex gap-3 items-end">
        <div><label className="text-xs text-[var(--text-secondary)]">Family</label><input className="input" value={form.family} onChange={e => setForm({...form, family: e.target.value})} /></div>
        <div><label className="text-xs text-[var(--text-secondary)]">Manufacturer</label><input className="input" value={form.manufacturer} onChange={e => setForm({...form, manufacturer: e.target.value})} /></div>
        <div><label className="text-xs text-[var(--text-secondary)]">Match Pattern</label><input className="input" value={form.matchPattern} onChange={e => setForm({...form, matchPattern: e.target.value})} /></div>
        <button onClick={save} className="btn-primary text-sm">{editId ? 'Update' : 'Add'}</button>
      </div>
      <table className="data-table">
        <thead><tr><th>Family</th><th>Manufacturer</th><th>Match</th><th>Actions</th></tr></thead>
        <tbody>
          {models.map(m => (
            <tr key={m.id}>
              <td>{m.family}</td>
              <td>{m.manufacturer}</td>
              <td className="font-mono text-xs">{m.matchPattern}</td>
              <td>
                <button onClick={() => { setEditId(m.id); setForm({ family: m.family, manufacturer: m.manufacturer, matchPattern: m.matchPattern }); }} className="text-[var(--cyan)] mr-2">✎</button>
                <button onClick={() => remove(m.id)} className="text-[var(--red)]">✕</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AdminUsers({ users, token, onRefresh, showToast }: { users: User[]; token: string; onRefresh: () => void; showToast: (m: string) => void }) {
  const [form, setForm] = useState({ username: '', password: '', role: 'user' });
  const [resetUser, setResetUser] = useState<string | null>(null);
  const [newPassword, setNewPassword] = useState('');

  const safeUsers = Array.isArray(users) ? users : [];

  const create = async () => {
    try {
      await api('/api/users', 'POST', form, token);
      onRefresh();
      setForm({ username: '', password: '', role: 'user' });
      showToast('User created');
    } catch (e: any) { showToast(e.message); }
  };

  const resetPassword = async () => {
    if (!resetUser || !newPassword) return;
    try {
      await api(`/api/users/${resetUser}`, 'PATCH', { password: newPassword }, token);
      setResetUser(null);
      setNewPassword('');
      showToast('Password reset');
    } catch (e: any) { showToast(e.message); }
  };

  const remove = async (name: string) => {
    if (!confirm(`Delete user ${name}?`)) return;
    try { await api(`/api/users/${name}`, 'DELETE', null, token); onRefresh(); showToast('Deleted'); } catch (e: any) { showToast(e.message); }
  };

  const changeRole = async (name: string, role: string) => {
    try { await api(`/api/users/${name}`, 'PATCH', { role }, token); onRefresh(); showToast('Role updated'); } catch (e: any) { showToast(e.message); }
  };

  return (
    <div className="panel space-y-4">
      <h3 className="font-display" style={{color:'var(--amber)'}}>USER MANAGEMENT</h3>
      <div className="flex gap-3 items-end">
        <div><label className="text-xs text-[var(--text-secondary)]">Username</label><input className="input" value={form.username} onChange={e => setForm({...form, username: e.target.value})} /></div>
        <div><label className="text-xs text-[var(--text-secondary)]">Password</label><input className="input" type="password" value={form.password} onChange={e => setForm({...form, password: e.target.value})} /></div>
        <div><label className="text-xs text-[var(--text-secondary)]">Role</label>
          <select className="input" value={form.role} onChange={e => setForm({...form, role: e.target.value})}>
            <option value="user">User</option><option value="admin">Admin</option>
          </select></div>
        <button onClick={create} className="btn-primary text-sm">Create</button>
      </div>

      {resetUser && (
        <div className="flex gap-2 items-end p-3 rounded" style={{background:'var(--bg-card)'}}>
          <span className="text-sm">Reset password for <b>{resetUser}</b>:</span>
          <input className="input max-w-[200px]" type="password" placeholder="New password" value={newPassword} onChange={e => setNewPassword(e.target.value)} />
          <button onClick={resetPassword} className="btn-primary text-sm">Set</button>
          <button onClick={() => setResetUser(null)} className="btn-secondary text-sm">Cancel</button>
        </div>
      )}

      <table className="data-table">
        <thead><tr><th>Username</th><th>Role</th><th>Created</th><th>Actions</th></tr></thead>
        <tbody>
          {safeUsers.map(u => (
            <tr key={u.name}>
              <td>{u.name}</td>
              <td>
                <select className="bg-transparent border border-[var(--border)] rounded px-2 py-0.5 text-xs" value={u.role} onChange={e => changeRole(u.name, e.target.value)}>
                  <option value="user">user</option><option value="admin">admin</option>
                </select>
              </td>
              <td className="text-xs">{formatDate(u.createdAt || '')}</td>
              <td>
                <button onClick={() => setResetUser(u.name)} className="text-[var(--amber)] mr-2" title="Reset password">🔑</button>
                <button onClick={() => remove(u.name)} className="text-[var(--red)]">✕</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// ==================== HELP VIEW ====================
function HelpView() {
  return (
    <div className="panel max-w-3xl mx-auto space-y-4">
      <h2 className="font-display text-2xl font-bold" style={{color:'var(--amber)'}}>TESTDECK HELP</h2>

      <section>
        <h3 className="font-display text-lg mb-2" style={{color:'var(--cyan)'}}>Getting Started</h3>
        <ol className="list-decimal list-inside space-y-2 text-sm text-[var(--text-secondary)]">
          <li>Start the server: <code className="font-mono bg-[var(--bg-card)] px-2 py-0.5 rounded">start-server.bat</code></li>
          <li>On each bench PC, start the probe: <code className="font-mono bg-[var(--bg-card)] px-2 py-0.5 rounded">start-probe.bat</code></li>
          <li>Open browser to <code className="font-mono bg-[var(--bg-card)] px-2 py-0.5 rounded">http://server:8080</code></li>
          <li>Log in with admin credentials</li>
          <li>Run tests via "New Test" wizard</li>
        </ol>
      </section>

      <section>
        <h3 className="font-display text-lg mb-2" style={{color:'var(--cyan)'}}>Architecture</h3>
        <ul className="list-disc list-inside space-y-1 text-sm text-[var(--text-secondary)]">
          <li><b>Server</b> (server.ps1): PowerShell HTTP server, JSON database, auth</li>
          <li><b>Probe</b> (probe.ps1): Drive inventory + Win32 benchmarks</li>
          <li><b>Console</b> (this page): React SPA for tests and analytics</li>
        </ul>
      </section>

      <section>
        <h3 className="font-display text-lg mb-2" style={{color:'var(--cyan)'}}>Verdicts</h3>
        <ul className="list-disc list-inside space-y-1 text-sm text-[var(--text-secondary)]">
          <li><span className="badge badge-pass">PASS</span>: Health OK, wear &lt;70%, speed meets profile</li>
          <li><span className="badge badge-watch">WATCH</span>: Warning health or wear 70-89% or speed LOW</li>
          <li><span className="badge badge-fail">FAIL</span>: Unhealthy, wear ≥90%, integrity errors, or speed FAIL</li>
        </ul>
      </section>
    </div>
  );
}
